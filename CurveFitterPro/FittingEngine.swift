import Foundation
import Combine

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
    let compiled = try CompiledExpression(source: input.expression)

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

    let paramDict = Dictionary(uniqueKeysWithValues: zip(input.paramNames, lmResult.parameters))
    let fittedY = input.dataX.map { x in
        (try? compiled.evaluate(x: x, parameters: paramDict)) ?? .nan
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

@MainActor
final class FittingEngine: ObservableObject {

    @Published var isFitting = false
    @Published var statusMessage = ""
    @Published var progress: Double = 0

    // MARK: - Run Fit

    func fit(project: Project) async -> FitResult? {
        // ── Gather all data on the main actor before leaving it ──────────
        let dataPoints = project.dataPoints.filter { !$0.isOutlier }
        guard dataPoints.count >= 2 else {
            statusMessage = "Need at least 2 data points"
            return nil
        }
        let expressionSource = project.modelExpression
        guard !expressionSource.isEmpty else {
            statusMessage = "No model expression set"
            return nil
        }
        let params = project.parameters
        guard !params.isEmpty else {
            statusMessage = "No parameters defined"
            return nil
        }

        // Bundle everything into a Sendable value type
        let input = FitInput(
            dataX:         dataPoints.map(\.x),
            dataY:         dataPoints.map(\.y),
            weights:       dataPoints.map(\.weight),
            initialValues: params.map(\.initialValue),
            paramNames:    params.map(\.name),
            lowerBounds:   params.map(\.lowerBound),
            upperBounds:   params.map(\.upperBound),
            expression:    expressionSource
        )

        isFitting = true
        progress = 0
        statusMessage = "Fitting…"

        // ── Heavy compute off the main actor ─────────────────────────────
        let output: FitOutput? = await Task.detached(priority: .userInitiated) {
            try? await runFit(input)
        }.value

        // ── Back on main actor ────────────────────────────────────────────
        isFitting = false
        if let output {
            statusMessage = output.converged
                ? "Fit converged in \(output.iterations) iterations"
                : output.message
            return output.toFitResult()
        } else {
            statusMessage = "Fit failed — check expression and initial guesses"
            return nil
        }
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
        dof: Int
    ) -> [(lower: Double, upper: Double)] {
        let tCrit = FittingEngine.tCritical95(dof: dof)
        let eps = 1e-6

        return xValues.map { x in
            let paramDict = Dictionary(uniqueKeysWithValues: zip(paramNames, fittedParams))
            let yhat = (try? expression.evaluate(x: x, parameters: paramDict)) ?? .nan

            var grad = Array(repeating: 0.0, count: fittedParams.count)
            for j in 0..<fittedParams.count {
                let delta = max(eps, abs(fittedParams[j]) * eps)
                var pPlus  = fittedParams; pPlus[j]  += delta
                var pMinus = fittedParams; pMinus[j] -= delta
                let dPlus  = Dictionary(uniqueKeysWithValues: zip(paramNames, pPlus))
                let dMinus = Dictionary(uniqueKeysWithValues: zip(paramNames, pMinus))
                let yp = (try? expression.evaluate(x: x, parameters: dPlus))  ?? yhat
                let ym = (try? expression.evaluate(x: x, parameters: dMinus)) ?? yhat
                grad[j] = (yp - ym) / (2.0 * delta)
            }

            var variance = 0.0
            for i in 0..<fittedParams.count {
                for j in 0..<fittedParams.count {
                    variance += grad[i] * covMatrix[i][j] * grad[j]
                }
            }
            let halfWidth = tCrit * sqrt(max(0, variance))
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
        let paramDict = Dictionary(uniqueKeysWithValues: zip(paramNames, params))
        return (0..<nPoints).compactMap { i in
            let x = xMin + (xMax - xMin) * Double(i) / Double(nPoints - 1)
            guard let y = try? expression.evaluate(x: x, parameters: paramDict),
                  y.isFinite else { return nil }
            return (x, y)
        }
    }
}
