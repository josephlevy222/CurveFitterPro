import Foundation
import Combine
import Accelerate // Used for high-performance vector operations if needed

// MARK: - Fitting Engine
//
// High-level coordinator between the UI, expression parser, and LM solver.
//
// Swift 6 concurrency strategy:
//   - FittingEngine is @MainActor for UI-published properties.
//   - All data needed by the background task is copied into plain Sendable
//     value types (structs, arrays of Double/String) BEFORE Task.detached.
//   - The heavy compute runs in a nonisolated free function so Swift 6 can
//     verify no actor-isolated state is touched off the main actor.

// MARK: - Background input/output bundles (all Sendable value types)

struct FitInput: Sendable {
    let dataX: [Double]
    let dataY: [Double]
    let weights: [Double]
    let initialValues: [Double]
    let paramNames: [String]
    let lowerBounds: [Double]
    let upperBounds: [Double]
    let expression: String      // re-compiled on background thread
}

struct FitOutput: Sendable {
    let parameters: [FitParameter]
    let rSquared: Double
    let adjustedRSquared: Double
    let residualSumOfSquares: Double
    let reducedChiSquared: Double
    let iterations: Int
    let converged: Bool
    let message: String
    let residuals: [Double]
    let fittedY: [Double]
    let covarianceMatrix: [[Double]]

    func toFitResult() -> FitResult {
        FitResult(
            parameters: parameters,
            rSquared: rSquared,
            adjustedRSquared: adjustedRSquared,
            residualSumOfSquares: residualSumOfSquares,
            reducedChiSquared: reducedChiSquared,
            iterations: iterations,
            converged: converged,
            message: message,
            residuals: residuals,
            fittedY: fittedY,
            covarianceMatrix: covarianceMatrix
        )
    }
}

// MARK: - Pure compute function (nonisolated, Sendable-safe)

private func runFit(_ input: FitInput) async throws -> FitOutput {
    let compiled = try CompiledExpression(source: input.expression.replacingOccurrences(of: "\"", with: ""))

    let lmResult = LMSolver.solve(
        dataX: input.dataX,
        dataY: input.dataY,
        weights: input.weights,
        initialParams: input.initialValues,
        paramNames: input.paramNames,
        lowerBounds: input.lowerBounds,
        upperBounds: input.upperBounds,
        expression: compiled
    )

    let dof = max(1, input.dataX.count - input.initialValues.count)
    let tCrit = FittingEngine.tCritical95(dof: dof)

    var fittedParams: [FitParameter] = zip(input.paramNames, input.initialValues).map {
        FitParameter(name: $0.0, initialValue: $0.1)
    }
    for i in fittedParams.indices {
        fittedParams[i].fittedValue            = lmResult.parameters[i]
        fittedParams[i].standardError          = lmResult.standardErrors[i]
        fittedParams[i].confidenceIntervalLow  = lmResult.parameters[i] - tCrit * lmResult.standardErrors[i]
        fittedParams[i].confidenceIntervalHigh = lmResult.parameters[i] + tCrit * lmResult.standardErrors[i]
    }

    //let paramDict = Dictionary(uniqueKeysWithValues: zip(input.paramNames, lmResult.parameters))
    let fittedY = input.dataX.map { x in
        let yModel = compiled.evaluateFast(x: x, parameters: lmResult.parameters)
        guard yModel.isFinite else {
            return 1e10 // A safe penalty value instead of throwing an exception
        }
        return yModel
    }

    return FitOutput(
        parameters: fittedParams,
        rSquared: lmResult.rSquared,
        adjustedRSquared: lmResult.adjustedRSquared,
        residualSumOfSquares: lmResult.rss,
        reducedChiSquared: lmResult.reducedChiSquared,
        iterations: lmResult.iterations,
        converged: lmResult.converged,
        message: lmResult.terminationReason,
        residuals: lmResult.residuals,
        fittedY: fittedY,
        covarianceMatrix: lmResult.covarianceMatrix
    )
}

// MARK: - FittingEngine
import SwiftUI
@MainActor
final class FittingEngine: ObservableObject {
    
    @Published var isFitting = false
    @Published var statusMessage = ""
    @Published var progress: Double = 0
    
    // MARK: - Run Fit
    
    /// The caller's parameter array (typically `project.parameters`) may not be in the same order the parser assigns internally to `evaluator` —
    /// e.g. stale UI state, a model whose stored `parameterNames` metadata doesn't match its expression, or a hand-typed custom expression where
    /// names were detected in a different order than they're stored.
    ///
    /// Reconciling by name here guarantees `beta[j]` always means what `evaluator.parameterNames[j]` means for every solver step downstream.
    /// Without this, the optimizer still converges to a correct curve (it only ever sees `beta`'s positions, never names), but the fitted
    /// values end up attached to the wrong parameter names in the result — which is invisible in the plotted curve but wrong in any by-name
    /// display, like the parameter list or a substituted-equation annotation.
    private func reconcile(_ parameters: [FitParameter], to evaluator: CompiledExpression) -> [FitParameter] {
        let byName = Dictionary(parameters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return evaluator.parameterNames.map { name in
            byName[name] ?? FitParameter(name: name, initialValue: 1.0)
        }
    }
    
    
    
    
    /// Executes a bounded Levenberg-Marquardt non-linear least squares optimization loop
    func executeLMSolver(project: Project, parameters: [FitParameter]) async -> FitResult? {
        // 1. Setup compilation and filter active data points
        guard let evaluator = try? CompiledExpression(source: project.modelExpression) else {
            return nil
        }
        let parameters = reconcile(parameters, to: evaluator)
        
        let activePoints = project.dataPoints.filter { !$0.isOutlier }
        guard activePoints.count > parameters.count else {
            return FitResult(
                parameters: parameters, rSquared: 0, adjustedRSquared: 0,
                residualSumOfSquares: 0, reducedChiSquared: 0, iterations: 0,
                converged: false, message: "Error: More parameters than data points.",
                residuals: [], fittedY: [], covarianceMatrix: []
            )
        }
        
        let N = activePoints.count
        let M = parameters.count
        
        // Extract parameter values and bounds into flat arrays for hot loop execution
        var beta = parameters.map { $0.initialValue }
        let lowerBounds = parameters.map { $0.lowerBound }
        let upperBounds = parameters.map { $0.upperBound }
        
        // LM Hyperparameters
        var lambda = 0.001
        let v = 10.0
        let maxIterations = 100
        let tolerance = 1e-6
        
        var iterations = 0
        var converged = false
        var statusMessage = "Max iterations reached without convergence."
        
        // Calculate initial cost (Weighted Chi-Squared)
        var chi2 = calculateChi2(evaluator: evaluator, beta: beta, points: activePoints)
        
        // Main Levenberg-Marquardt Optimization Loop
        while iterations < maxIterations && !converged {
            iterations += 1
            
            // Step A: Compute Residuals and Jacobian Matrix (N x M)
            let residuals = computeResiduals(evaluator: evaluator, beta: beta, points: activePoints)
            let jacobian = computeJacobian(evaluator: evaluator, beta: beta, points: activePoints, residuals: residuals)
            
            // Step B: Form Normal Equations (Jᵀ · W · J) and Gradient Vector (Jᵀ · W · r)
            var JTJ = [Double](repeating: 0.0, count: M * M)
            var JTr = [Double](repeating: 0.0, count: M)
            
            for i in 0..<N {
                let w = activePoints[i].weight
                let r = residuals[i]
                for j in 0..<M {
                    let jj = i * M + j
                    JTr[j] += jacobian[jj] * w * r
                    for k in 0..<M {
                        JTJ[j * M + k] += jacobian[jj] * w * jacobian[i * M + k]
                    }
                }
            }
            
            // Step C: Apply Levenberg Damping Factor to Diagonal elements
            var A = JTJ
            for j in 0..<M {
                A[j * M + j] += lambda * max(1.0, JTJ[j * M + j])
            }
            
            // Step D: Solve linear system A · delta = JTr using Gaussian Elimination
            guard let delta = solveLinearSystem(matrix: A, vector: JTr, size: M) else {
                statusMessage = "Matrix became singular or poorly conditioned."
                break
            }
            
            // Step E: Compute candidate parameter updates with boundary clamping
            var nextBeta = beta
            for j in 0..<M {
                nextBeta[j] = max(lowerBounds[j], min(upperBounds[j], beta[j] + delta[j]))
            }
            
            // Step F: Evaluate cost of proposed steps
            let nextChi2 = calculateChi2(evaluator: evaluator, beta: nextBeta, points: activePoints)
            
            if nextChi2 < chi2 {
                // Success: Accept step updates, decrease damping factor
                let stepNorm = sqrt(delta.reduce(0.0) { $0 + $1 * $1 })
                if (chi2 - nextChi2) / chi2 < tolerance || stepNorm < tolerance {
                    converged = true
                    statusMessage = "Converged successfully."
                }
                
                beta = nextBeta
                chi2 = nextChi2
                lambda /= v
            } else {
                // Failure: Reject step layout updates, increase dampening penalty
                lambda *= v
                if lambda > 1e12 {
                    statusMessage = "Optimizer stalled: Lambda limit reached."
                    break
                }
            }
        }
        
        // 2. Convergence Post-Processing (Compute Statistics & Errors)
        let finalResiduals = computeResiduals(evaluator: evaluator, beta: beta, points: activePoints)
        let finalJacobian = computeJacobian(evaluator: evaluator, beta: beta, points: activePoints, residuals: finalResiduals)
        
        // Rebuild un-damped JᵀWJ for exact asymptotic covariance calculations
        var JTJ_final = [Double](repeating: 0.0, count: M * M)
        for i in 0..<N {
            let w = activePoints[i].weight
            for j in 0..<M {
                for k in 0..<M {
                    JTJ_final[j * M + k] += finalJacobian[i * M + j] * w * finalJacobian[i * M + k]
                }
            }
        }
        
        let covMatrixFlat = invertMatrix(JTJ_final, size: M) ?? [Double](repeating: 0.0, count: M * M)
        let degreesOfFreedom = Double(N - M)
        let reducedChi2 = chi2 / degreesOfFreedom
        
        // Map updates back to FitParameter identities
        var outParameters = parameters
        for j in 0..<M {
            let variance = covMatrixFlat[j * M + j] * (reducedChi2 > 0 ? reducedChi2 : 1.0)
            let standardError = variance > 0 ? sqrt(variance) : 0.0
            let tValue = 1.96 // Approximate 95% Confidence Interval multiplier
            
            outParameters[j].fittedValue = beta[j]
            outParameters[j].standardError = standardError
            outParameters[j].confidenceIntervalLow = beta[j] - (tValue * standardError)
            outParameters[j].confidenceIntervalHigh = beta[j] + (tValue * standardError)
        }
        
        // Compute structural summary statistics (R²)
        let yValues = activePoints.map(\.y)
        let yMean = yValues.reduce(0.0, +) / Double(N)
        let totalSumOfSquares = yValues.map { pow($0 - yMean, 2) }.reduce(0.0, +)
        let residualSumOfSquares = finalResiduals.map { pow($0, 2) }.reduce(0.0, +)
        
        let rSquared = totalSumOfSquares > 0 ? 1.0 - (residualSumOfSquares / totalSumOfSquares) : 0.0
        let adjRSquared = totalSumOfSquares > 0 ? 1.0 - ((residualSumOfSquares / degreesOfFreedom) / (totalSumOfSquares / Double(N - 1))) : 0.0
        
        let fittedY = activePoints.map { evaluator.evaluateFast(x: $0.x, parameters: beta) }
        
        // Reshape covariance flat projection array into multi-dimensional matrix layers
        let covarianceMatrix: [[Double]] = (0..<M).map { r in
            (0..<M).map { c in covMatrixFlat[r * M + c] }
        }
        
        return FitResult(
            parameters: outParameters,
            rSquared: rSquared,
            adjustedRSquared: adjRSquared,
            residualSumOfSquares: residualSumOfSquares,
            reducedChiSquared: reducedChi2,
            iterations: iterations,
            converged: converged,
            message: statusMessage,
            residuals: finalResiduals,
            fittedY: fittedY,
            covarianceMatrix: covarianceMatrix
        )
    }
    
    // MARK: - Core Linear Algebra & Differentiation Helpers
    
    private func computeResiduals(evaluator: CompiledExpression, beta: [Double], points: [DataPoint]) -> [Double] {
        return points.map { $0.y - evaluator.evaluateFast(x: $0.x, parameters: beta) }
    }
    
    private func calculateChi2(evaluator: CompiledExpression, beta: [Double], points: [DataPoint]) -> Double {
        return points.map { point in
            let res = point.y - evaluator.evaluateFast(x: point.x, parameters: beta)
            return res * res * point.weight
        }.reduce(0.0, +)
    }
    
    private func computeJacobian(evaluator: CompiledExpression, beta: [Double], points: [DataPoint], residuals: [Double]) -> [Double] {
        let N = points.count
        let M = beta.count
        var jacobian = [Double](repeating: 0.0, count: N * M)
        let h = 1e-8 // Finite step size
        
        for j in 0..<M {
            var perturbedBeta = beta
            perturbedBeta[j] += h
            
            for i in 0..<N {
                let perturbedY = evaluator.evaluateFast(x: points[i].x, parameters: perturbedBeta)
                let originalY = points[i].y - residuals[i]
                // Partial derivative: -dy/dβ
                jacobian[i * M + j] = -(perturbedY - originalY) / h
            }
        }
        return jacobian
    }
    
    /// Solves A · x = B using Gaussian Elimination with partial pivoting
    private func solveLinearSystem(matrix: [Double], vector: [Double], size N: Int) -> [Double]? {
        var a = matrix
        var b = vector
        
        for i in 0..<N {
            // Find pivot row
            var maxRow = i
            for k in (i + 1)..<N {
                if abs(a[k * N + i]) > abs(a[maxRow * N + i]) { maxRow = k }
            }
            
            // Swap rows
            if maxRow != i {
                for j in i..<N { a.swapAt(i * N + j, maxRow * N + j) }
                b.swapAt(i, maxRow)
            }
            
            if abs(a[i * N + i]) < 1e-12 { return nil } // Singular matrix boundary
            
            // Eliminate elements downstream
            for k in (i + 1)..<N {
                let factor = a[k * N + i] / a[i * N + i]
                for j in i..<N { a[k * N + j] -= factor * a[i * N + j] }
                b[k] -= factor * b[i]
            }
        }
        
        // Back substitution phase
        var x = [Double](repeating: 0.0, count: N)
        for i in (0..<N).reversed() {
            var sum = b[i]
            for j in (i + 1)..<N { sum -= a[i * N + j] * x[j] }
            x[i] = sum / a[i * N + i]
        }
        return x
    }
    
    /// Inverts an NxN matrix using standard Gauss-Jordan Elimination
    private func invertMatrix(_ matrix: [Double], size N: Int) -> [Double]? {
        var a = matrix
        var inv = [Double](repeating: 0.0, count: N * N)
        for i in 0..<N { inv[i * N + i] = 1.0 } // Seed identity grid structure
        
        for i in 0..<N {
            var maxRow = i
            for k in (i + 1)..<N {
                if abs(a[k * N + i]) > abs(a[maxRow * N + i]) { maxRow = k }
            }
            if maxRow != i {
                for j in 0..<N {
                    a.swapAt(i * N + j, maxRow * N + j)
                    inv.swapAt(i * N + j, maxRow * N + j)
                }
            }
            
            let pivot = a[i * N + i]
            if abs(pivot) < 1e-12 { return nil }
            
            for j in 0..<N {
                a[i * N + j] /= pivot
                inv[i * N + j] /= pivot
            }
            
            for k in 0..<N {
                if k == i { continue }
                let factor = a[k * N + i]
                for j in 0..<N {
                    a[k * N + j] -= factor * a[i * N + j]
                    inv[k * N + j] -= factor * inv[i * N + j]
                }
            }
        }
        return inv
    }
    
    // Generates an alternative guess vector by adding scaled stochastic noise
    func perturbGuesses(currentParameters: [FitParameter], data: [DataPoint]) -> [Double] {
        let yValues = data.map(\.y)
        let ySpread = (yValues.max() ?? 1.0) - (yValues.min() ?? 0.0)
        
        return currentParameters.map { param in
            let range = param.upperBound - param.lowerBound
            
            // If the parameter is bounded, pick a new point 25% away from the current spot
            if range.isFinite {
                let shift = range * 0.25 * Double.random(in: -1...1)
                return max(param.lowerBound, min(param.upperBound, param.initialValue + shift))
            }
            
            // For unbounded parameters, apply a multiplicative kick based on magnitude
            let magnitude = abs(param.initialValue) > 0 ? abs(param.initialValue) : (ySpread > 0 ? ySpread : 1.0)
            let kick = magnitude * Double.random(in: 0.5...2.0) * (Bool.random() ? 1.0 : -1.0)
            
            return param.initialValue + kick
        }
    }
    
    // Sweeps the parameter space using a randomized Monte Carlo search to locate valid gradient basins
    private func exploreParameterSpace(
        evaluator: CompiledExpression,
        parameters: [FitParameter],
        activePoints: [DataPoint],
        sampleCount: Int = 100
    ) -> [Double] {
        let M = parameters.count
        
        // Establish reasonable fallback boundaries based on data dimensions if bounds are infinite
        let xValues = activePoints.map(\.x)
        let yValues = activePoints.map(\.y)
        let yMax = yValues.max() ?? 1.0
        let yMin = yValues.min() ?? 0.0
        let ySpread = abs(yMax - yMin) > 0 ? abs(yMax - yMin) : 1.0
        let xSpreadRaw = abs((xValues.max() ?? 1.0) - (xValues.min() ?? 0.0))
        let xSpread = xSpreadRaw > 0 ? xSpreadRaw : 1.0
        
        var bestBeta = parameters.map { $0.initialValue }
        var minChi2 = calculateChi2(evaluator: evaluator, beta: bestBeta, points: activePoints)
        
        for _ in 0..<sampleCount {
            var candidateBeta = [Double](repeating: 0.0, count: M)
            
            for j in 0..<M {
                let param = parameters[j]
                let low = param.lowerBound.isFinite ? param.lowerBound : -ySpread * 5.0
                let high = param.upperBound.isFinite ? param.upperBound : ySpread * 5.0
                
                // Generate a random position inside the parameter's valid corridor
                candidateBeta[j] = Double.random(in: low...high)
                
                // Smart heuristic adjustment: if the parameter name implies an offset or scale,
                // tailor its initialization space to the data scale
                if !param.lowerBound.isFinite && !param.upperBound.isFinite {
                    let name = param.name.lowercased()
                    if name.contains("offset") || name.contains("bg") {
                        candidateBeta[j] = Double.random(in: yMin...yMax)
                    } else if name.contains("scale") || name.contains("amp") {
                        candidateBeta[j] = Double.random(in: (-ySpread)...(ySpread))
                    } else if name.contains("rate") || name.contains("freq") || name.contains("k") {
                        candidateBeta[j] = Double.random(in: (1.0 / xSpread)...(10.0 / xSpread))
                    }
                }
            }
            
            let currentChi2 = calculateChi2(evaluator: evaluator, beta: candidateBeta, points: activePoints)
            
            // If this candidate matches the data better, keep it
            if currentChi2 < minChi2 && currentChi2.isFinite {
                minChi2 = currentChi2
                bestBeta = candidateBeta
            }
        }
        
        return bestBeta
    }
    
    /// Executes a derivative-free Hooke-Jeeves pattern search ("hunting") algorithm to crawl off flat plateaus and locate a valid optimization basin.
    private func huntParameterSpace(
        evaluator: CompiledExpression,
        parameters: [FitParameter],
        activePoints: [DataPoint],
        maxIterations: Int = 300
    ) -> [Double] {
        let M = parameters.count
        
        var basePoint = parameters.map { $0.initialValue }
        var currentPoint = basePoint
        var bestChi2 = calculateChi2(evaluator: evaluator, beta: basePoint, points: activePoints)
        
        // Step 1: Initialize step sizes dynamically based on bounds or parameter magnitudes
        var steps = [Double](repeating: 0.0, count: M)
        for j in 0..<M {
            let param = parameters[j]
            if param.upperBound.isFinite && param.lowerBound.isFinite {
                steps[j] = (param.upperBound - param.lowerBound) * 0.1
            } else {
                steps[j] = abs(param.initialValue) > 0 ? abs(param.initialValue) * 0.15 : 0.5
            }
            if steps[j] == 0 { steps[j] = 0.1 }
        }
        
        let stepReductionFactor = 0.5
        let terminationTolerance = 1e-5
        var iteration = 0
        
        // Step 2: Main Hunting Loop
        while iteration < maxIterations {
            iteration += 1
            
            // Phase A: Conduct an exploratory step array sequence around the current coordinate
            let (exploredPoint, exploredChi2) = executeExploratoryStep(
                evaluator: evaluator,
                points: activePoints,
                startPoint: currentPoint,
                steps: steps,
                parameters: parameters
            )
            
            if exploredChi2 < bestChi2 - 1e-9 {
                // Phase B: Success! Synthesize an accelerated Pattern Move along the winning vector direction
                var patternPoint = [Double](repeating: 0.0, count: M)
                for j in 0..<M {
                    // Pattern leap formula: P = E_new + (E_new - B_old)
                    patternPoint[j] = exploredPoint[j] + (exploredPoint[j] - basePoint[j])
                    patternPoint[j] = max(parameters[j].lowerBound, min(parameters[j].upperBound, patternPoint[j]))
                }
                
                basePoint = exploredPoint
                
                // Look ahead: explore around the leaped pattern position
                let (patternExploredPoint, patternExploredChi2) = executeExploratoryStep(
                    evaluator: evaluator,
                    points: activePoints,
                    startPoint: patternPoint,
                    steps: steps,
                    parameters: parameters
                )
                
                if patternExploredChi2 < exploredChi2 {
                    currentPoint = patternExploredPoint
                    bestChi2 = patternExploredChi2
                } else {
                    currentPoint = exploredPoint
                    bestChi2 = exploredChi2
                }
            } else {
                // Phase C: Failure. Shrink coordinate resolution steps down to pinpoint local valley limits
                var maximumStepSize = 0.0
                for j in 0..<M {
                    steps[j] *= stepReductionFactor
                    maximumStepSize = max(maximumStepSize, steps[j])
                }
                
                // If the search increment resolution gets down below the limit, the hunt concludes
                if maximumStepSize < terminationTolerance {
                    break
                }
                
                // Snap the current workspace coordinate back to the last confirmed base station anchor
                currentPoint = basePoint
            }
        }
        
        return basePoint
    }
    
    /// Helper coordinating step permutations for a standalone parameter node pass
    private func executeExploratoryStep(
        evaluator: CompiledExpression,
        points: [DataPoint],
        startPoint: [Double],
        steps: [Double],
        parameters: [FitParameter]
    ) -> (point: [Double], chi2: Double) {
        let M = startPoint.count
        var testPoint = startPoint
        var currentMinChi2 = calculateChi2(evaluator: evaluator, beta: testPoint, points: points)
        
        for j in 0..<M {
            let originalCoordinateValue = testPoint[j]
            
            // Coordinate option 1: Step forward
            let forwardPosition = max(parameters[j].lowerBound, min(parameters[j].upperBound, originalCoordinateValue + steps[j]))
            testPoint[j] = forwardPosition
            let forwardChi2 = calculateChi2(evaluator: evaluator, beta: testPoint, points: points)
            
            if forwardChi2 < currentMinChi2 {
                currentMinChi2 = forwardChi2
            } else {
                // Coordinate option 2: Step backward
                let backwardPosition = max(parameters[j].lowerBound, min(parameters[j].upperBound, originalCoordinateValue - steps[j]))
                testPoint[j] = backwardPosition
                let backwardChi2 = calculateChi2(evaluator: evaluator, beta: testPoint, points: points)
                
                if backwardChi2 < currentMinChi2 {
                    currentMinChi2 = backwardChi2
                } else {
                    // Element did not resolve a lower path coordinate step, reverse changes completely
                    testPoint[j] = originalCoordinateValue
                }
            }
        }
        
        return (testPoint, currentMinChi2)
    }
    
    func fit(project: Project) async -> FitResult? {
        isFitting = true
        statusMessage = "Executing primary gradient fit..."
        defer { isFitting = false }
        
        guard let evaluator = try? CompiledExpression(source: project.modelExpression) else {
            statusMessage = "Compilation Error: Invalid expression syntax."
            return nil
        }
        
        /// Reconcile once, up front, to the compiled expression's own parameter order — see reconcile(_:to:) above. huntParameterSpace/executeExploratoryStep
        /// don't go through executeLMSolver's own reconciliation, so they'd otherwise be feeding evaluator a beta vector in the wrong order too.
        let reconciledParams = reconcile(project.parameters, to: evaluator)
        
        let activePoints = project.dataPoints.filter { !$0.isOutlier }
        guard activePoints.count > reconciledParams.count else {
            statusMessage = "Error: Insufficient data points."
            return nil
        }
        
        // Attempt standard fast local optimization gradient scan
        var workingParams = reconciledParams
        var currentResult = await executeLMSolver(project: project, parameters: workingParams)
        
        let flatPlateauThreshold = 0.05
        
        /// The LM loop sometimes stalls -- hits maxIterations or the lambda ceiling without its convergence check firing -- even when it has
        /// actually landed close to the minimum. This is usually a damping factor that wandered to a bad value, not a genuinely lost search:
        /// restarting the solver from exactly where it stopped, with a fresh lambda, typically finishes the job in a couple more passes. This
        /// automates what was previously "tap Run Fit again a couple times."  Gated on R² already being past the flat-plateau threshold, since a
        /// restart from a genuinely bad point is unlikely to help -- that case is better served by the pattern-hunt escape below.
        let maxRestarts = 3
        var restarts = 0
        while let result = currentResult,
              !result.converged,
              result.rSquared > flatPlateauThreshold,
              restarts < maxRestarts {
            restarts += 1
            statusMessage = "Stalled near a minimum, restarting solver (\(restarts)/\(maxRestarts))..."
            
            for i in workingParams.indices where i < result.parameters.count {
                if let v = result.parameters[i].fittedValue {
                    workingParams[i].initialValue = v
                }
            }
            
            guard let freshResult = await executeLMSolver(project: project, parameters: workingParams) else {
                break
            }
            /// Always take it if it actually converged; otherwise only keep the restart if it's at least as good, so a pathological restart
            /// can't silently regress the result. Track total iterations spent across every restart, not just the last leg, for an accurate count.
            guard freshResult.converged || freshResult.rSquared >= result.rSquared else {
                break
            }
            var accumulated = freshResult
            accumulated.iterations += result.iterations
            currentResult = accumulated
        }
        
        // Escape path: If stuck on a flat line plateau, trigger the pattern hunting engine
        if currentResult == nil || !currentResult!.converged || currentResult!.rSquared <= flatPlateauThreshold {
            statusMessage = "Stuck on flat plateau (R² ≤ 0.05). Launching Pattern Hunt Search..."
            
            // Execute the direct coordinate tracking search
            let huntedGuesses = huntParameterSpace(
                evaluator: evaluator,
                parameters: workingParams,
                activePoints: activePoints
            )
            
            // Re-inject the optimized layout vector coordinates discovered by the hunt loop
            for i in workingParams.indices {
                workingParams[i].initialValue = huntedGuesses[i]
            }
            
            statusMessage = "Basin identified via pattern hunt. Polishing parameters..."
            
            // Run LM a second time to lock onto the precise global minimum minimum and compute accurate Covariance Errors
            if let polishedResult = await executeLMSolver(project: project, parameters: workingParams) {
                if polishedResult.rSquared > (currentResult?.rSquared ?? -Double.infinity) {
                    currentResult = polishedResult
                }
            }
        }
        
        if let finalResult = currentResult {
            statusMessage = finalResult.rSquared <= flatPlateauThreshold
            ? "Warning: Unable to locate an optimization basin. Verify constraints."
            : finalResult.message
            return finalResult
        }
        
        return nil
    }
    
    // MARK: - Confidence Band
    //
    // All inputs are plain value types so this is safely callable from @MainActor.
    
    func confidenceBand(
        xValues: [Double],
        fittedParams: [Double],
        paramNames: [String],
        covMatrix: [[Double]],
        expression: CompiledExpression,
        dof: Int,
        confidenceLevel: Int = 95
    ) -> [(lower: Double, upper: Double)] {
        let tCrit: Double
        switch confidenceLevel {
        case 90: tCrit = FittingEngine.tCritical90(dof: dof)
        case 99: tCrit = FittingEngine.tCritical99(dof: dof)
        default: tCrit = FittingEngine.tCritical95(dof: dof)
        }
        let eps = 1e-6
        
        return xValues.map { x in
            let yhat = expression.evaluateFast(x: x, parameters: fittedParams)
            
            var grad = Array(repeating: 0.0, count: fittedParams.count)
            for j in 0..<fittedParams.count {
                let delta = max(eps, abs(fittedParams[j]) * eps)
                var pPlus  = fittedParams; pPlus[j]  += delta
                var pMinus = fittedParams; pMinus[j] -= delta
                let yp = expression.evaluateFast(x: x, parameters: pPlus)
                let ym = expression.evaluateFast(x: x, parameters: pMinus)
                grad[j] = (yp - ym) / (2.0 * delta)
            }
            
            var variance = 0.0
            for i in 0..<fittedParams.count {
                for j in 0..<fittedParams.count {
                    variance += grad[i] * covMatrix[i][j] * grad[j]
                }
            }
            guard yhat.isFinite else { return (yhat, yhat) }
            let halfWidth = tCrit * sqrt(max(0, variance))
            guard halfWidth.isFinite else { return (yhat, yhat) }
            return (yhat - halfWidth, yhat + halfWidth)
        }
    }
    
    // MARK: - t critical value (95%, two-tailed)
    
    static func tCritical95(dof: Int) -> Double {
        switch dof {
        case 1:       return 12.706
        case 2:       return 4.303
        case 3:       return 3.182
        case 4:       return 2.776
        case 5:       return 2.571
        case 6:       return 2.447
        case 7:       return 2.365
        case 8:       return 2.306
        case 9:       return 2.262
        case 10:      return 2.228
        case 11...20: return 2.086 + (2.228 - 2.086) * Double(20 - dof) / 9.0
        case 21...30: return 2.042 + (2.086 - 2.042) * Double(30 - dof) / 9.0
        default:
            if dof >= 120 { return 1.960 }
            return 1.960 + 1.0 / Double(dof)
        }
    }
    
    // MARK: - Smooth curve for plotting
    
    func smoothCurve(
        xMin: Double,
        xMax: Double,
        nPoints: Int = 400,
        params: [Double],
        paramNames: [String],
        expression: CompiledExpression
    ) -> [(x: Double, y: Double)] {
        //let paramDict = Dictionary(uniqueKeysWithValues: zip(paramNames, params))
        return (0..<nPoints).compactMap { i in
            let x = xMin + (xMax - xMin) * Double(i) / Double(nPoints - 1)
            let y = /* try? */expression.evaluateFast(x: x, parameters: params)/*,*/
            guard y.isFinite else { return nil }
            return (x, y)
        }
    }
    
    // MARK: - t critical values (90%, two-tailed)
    static func tCritical90(dof: Int) -> Double {
        switch dof {
        case 1:  return 6.314
        case 2:  return 2.920
        case 3:  return 2.353
        case 4:  return 2.132
        case 5:  return 2.015
        case 6:  return 1.943
        case 7:  return 1.895
        case 8:  return 1.860
        case 9:  return 1.833
        case 10: return 1.812
        case 11: return 1.796
        case 12: return 1.782
        case 13: return 1.771
        case 14: return 1.761
        case 15: return 1.753
        case 16: return 1.746
        case 17: return 1.740
        case 18: return 1.734
        case 19: return 1.729
        case 20: return 1.725
        case 21...25:  return 1.711
        case 26...30:  return 1.697
        case 31...40:  return 1.684
        case 41...60:  return 1.671
        case 61...120: return 1.658
        default:       return 1.645   // z∞
        }
    }
    
    // MARK: - t critical values (99%, two-tailed)
    static func tCritical99(dof: Int) -> Double {
        switch dof {
        case 1:  return 63.657
        case 2:  return 9.925
        case 3:  return 5.841
        case 4:  return 4.604
        case 5:  return 4.032
        case 6:  return 3.707
        case 7:  return 3.499
        case 8:  return 3.355
        case 9:  return 3.250
        case 10: return 3.169
        case 11: return 3.106
        case 12: return 3.055
        case 13: return 3.012
        case 14: return 2.977
        case 15: return 2.947
        case 16: return 2.921
        case 17: return 2.898
        case 18: return 2.878
        case 19: return 2.861
        case 20: return 2.845
        case 21...25:  return 2.797
        case 26...30:  return 2.750
        case 31...40:  return 2.704
        case 41...60:  return 2.660
        case 61...120: return 2.617
        default:       return 2.576   // z∞
        }
    }
}
