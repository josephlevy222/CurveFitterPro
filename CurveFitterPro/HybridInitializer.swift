//
//  HybridInitializer.swift
//  CurveFitterPro
//
//  Created by Joseph Levy on 6/4/26.
//
import Foundation

struct HybridInitializer {
	
	/// Entry point for synthesizing high-quality starting guesses
	/// - Parameters:
	///   - project: The target project containing data points and parameter bounds
	///   - compiledEvaluator: An optional pre-compiled parser instance for custom equations
	/// - Returns: An array of guess values ordered matching `project.parameters`
	static func synthesizeGuesses(for project: Project, compiledEvaluator: CompiledExpression? = nil) -> [Double] {
		let validPoints = project.dataPoints.filter { !$0.isOutlier }
		guard !validPoints.isEmpty else {
			return project.parameters.map { $0.initialValue }
		}
		
		// 1. TIER 1: Check for known analytical heuristics
		if let heuristicGuesses = applyLibraryHeuristics(modelName: project.modelName, data: validPoints) {
			// Map dictionary results back to structural parameter definitions safely
			return project.parameters.map { param in
				if let guessedValue = heuristicGuesses[param.name] {
					// Clamp to user-defined explicit parameter boxes if present
					return max(param.lowerBound, min(param.upperBound, guessedValue))
				}
				return param.initialValue
			}
		}
		
		// 2. TIER 2: Fallback to a fast, global metaheuristic for arbitrary custom expressions
		guard let evaluator = compiledEvaluator ?? (try? CompiledExpression(source: project.modelExpression)) else {
			return project.parameters.map { $0.initialValue }
		}
		return runLightweightGlobalSearch(project: project, evaluator: evaluator, data: validPoints)
	}
	
	// MARK: - Tier 1: Analytical Data Scanning (0ms)
	
	private static func applyLibraryHeuristics(modelName: String, data: [DataPoint]) -> [String: Double]? {
		guard let summary = data.analyticsSummary() else { return nil }
		var guesses: [String: Double] = [:]
		
		switch modelName.lowercased() {
		case "gaussian", "peak":
			let baseline = summary.minY
			let amplitude = max(1e-4, summary.maxY - baseline)
			let centroid = summary.xAtYMax
			let spread = max(1e-4, (summary.maxX - summary.minX) / 4.0)
			
			guesses["y0"] = baseline
			guesses["a"] = amplitude
			guesses["x0"] = centroid
			guesses["sigma"] = spread
			return guesses
			
		case "exponential", "exp decay":
			let safeMinY = max(1e-4, summary.minY)
			let safeMaxY = max(2e-4, summary.maxY)
			guesses["a"] = safeMaxY
			
			let deltaX = max(1e-4, summary.maxX - summary.minX)
			let decaySign: Double = summary.xAtYMax < summary.xAtYMin ? -1.0 : 1.0
			guesses["b"] = decaySign * (log(safeMaxY) - log(safeMinY)) / deltaX
			return guesses
			
		case "sine", "sinusoidal":
			guesses["offset"] = (summary.maxY + summary.minY) / 2.0
			guesses["a"] = (summary.maxY - summary.minY) / 2.0
			
			let halfWavelength = abs(summary.xAtYMax - summary.xAtYMin)
			guesses["omega"] = halfWavelength > 0 ? (.pi / halfWavelength) : 1.0
			guesses["phi"] = 0.0
			return guesses
			
		default:
			return nil // Route to Tier 2
		}
	}
	
	// MARK: - Tier 2: Lightweight Bounded Differential Evolution
	
	private static func runLightweightGlobalSearch(
		project: Project,
		evaluator: CompiledExpression,
		data: [DataPoint]
	) -> [Double] {
		
		let dimensions = project.parameters.count
		guard dimensions > 0 else { return [] }
		
		// Hyperparameters scaled back to minimize dynamic AST evaluation overhead
		let populationSize = max(20, dimensions * 8)
		let maxGenerations = 25 // Short lifespan: just trying to land in the right valley
		let F = 0.7  // Differential mutation scale factor
		let CR = 0.5 // Crossover probability
		
		// Establish search limits based on explicit bounds, falling back to data scaling magnitudes
		let yMagnitude = max(abs(data.max(by: { abs($0.y) < abs($1.y) })?.y ?? 1.0), 1.0)
		let bounds: [(low: Double, high: Double)] = project.parameters.map { param in
			let low = param.lowerBound == -Double.infinity ? -yMagnitude * 5.0 : param.lowerBound
			let high = param.upperBound == Double.infinity ? yMagnitude * 5.0 : param.upperBound
			return (low, high)
		}
		
		// Initialize the tracking matrix population
		var population = [[Double]](repeating: [Double](repeating: 0.0, count: dimensions), count: populationSize)
		var fitness = [Double](repeating: Double.infinity, count: populationSize)
		
		// Helper to evaluate the weighted objective function ($\chi^2$)
		func computeWeightedRSS(for vector: [Double]) -> Double {
			var rss: Double = 0.0
			for i in 0..<data.count {
				let point = data[i]
				// Invoke fast parameter index mapping evaluation loop
                let yEstimated = evaluator.evaluateFast(x: point.x, parameters: vector)
				let residual = point.y - yEstimated
				rss += point.weight * residual * residual
			}
			return rss.isNaN ? Double.infinity : rss
		}
		
		// Seed first agent with current configuration, fill the rest uniformly
		population[0] = project.parameters.map { $0.initialValue }
		fitness[0] = computeWeightedRSS(for: population[0])
		
		for i in 1..<populationSize {
			for d in 0..<dimensions {
				population[i][d] = Double.random(in: bounds[d].low...bounds[d].high)
			}
			fitness[i] = computeWeightedRSS(for: population[i])
		}
		
		// Main Evolution Loop (DE/rand/1/bin strategy)
		for _ in 0..<maxGenerations {
			for i in 0..<populationSize {
				
				// Pick 3 distinct random agents != current index
				var r1 = i, r2 = i, r3 = i
				while r1 == i { r1 = Int.random(in: 0..<populationSize) }
				while r2 == i || r2 == r1 { r2 = Int.random(in: 0..<populationSize) }
				while r3 == i || r3 == r1 || r3 == r2 { r3 = Int.random(in: 0..<populationSize) }
				
				// Generate mutant candidate vector via difference vectors
				var candidate = population[i]
				let forcedCrossoverIndex = Int.random(in: 0..<dimensions)
				
				for d in 0..<dimensions {
					if Double.random(in: 0...1) < CR || d == forcedCrossoverIndex {
						let mutantValue = population[r1][d] + F * (population[r2][d] - population[r3][d])
						// Clamp to domain box parameters
						candidate[d] = max(bounds[d].low, min(bounds[d].high, mutantValue))
					}
				}
				
				// Selection phase based on cost minimization
				let candidateFitness = computeWeightedRSS(for: candidate)
				if candidateFitness < fitness[i] {
					population[i] = candidate
					fitness[i] = candidateFitness
				}
			}
		}
		
		// Locate champion vector
		if let bestIndex = fitness.indices.min(by: { fitness[$0] < fitness[$1] }) {
			return population[bestIndex]
		}
		return project.parameters.map { $0.initialValue }
	}
}

// MARK: - Internal Descriptive Metrics Extension
fileprivate extension Array where Element == DataPoint {
	func analyticsSummary() -> (minX: Double, maxX: Double, minY: Double, maxY: Double, xAtYMax: Double, xAtYMin: Double)? {
		guard !self.isEmpty else { return nil }
		
		let sortedByX = self.sorted { $0.x < $1.x }
		guard let firstX = sortedByX.first?.x, let lastX = sortedByX.last?.x else { return nil }
		
		guard let maxRow = self.max(by: { $0.y < $1.y }),
			  let minRow = self.min(by: { $0.y < $1.y }) else { return nil }
		
		return (
			minX: firstX,
			maxX: lastX,
			minY: minRow.y,
			maxY: maxRow.y,
			xAtYMax: maxRow.x,
			xAtYMin: minRow.x
		)
	}
}
