import Foundation
import Accelerate

// MARK: - LM Solver
//
// A pure-Swift implementation of the Levenberg-Marquardt algorithm
// for nonlinear least-squares curve fitting.
//
// Reference: Moré, J.J. (1978). The Levenberg-Marquardt algorithm:
//            Implementation and theory. Lecture Notes in Mathematics, 630.
//
// Numerical Jacobian via central finite differences.
// No analytical derivatives required from the caller.

struct LMSolver {

    // MARK: Configuration

    struct Config {
        var maxIterations: Int = 1000
        var functionTolerance: Double = 1e-8   // relative RSS improvement to stop
        var gradientTolerance: Double = 1e-8   // relative gradient norm to stop
        var stepTolerance: Double = 1e-8       // relative step size to stop
        var initialLambda: Double = 1e-3
        var lambdaUpFactor: Double = 10.0
        var lambdaDownFactor: Double = 10.0
        var finiteDiffEpsilon: Double = 1e-5   // larger eps is more robust
        var minIterations: Int = 2             // always take at least this many steps
    }

    // MARK: Result

    struct Result {
        var parameters: [Double]
        var residuals: [Double]
        var jacobian: [[Double]]   // nData × nParams
        var rss: Double            // residual sum of squares
        var iterations: Int
        var converged: Bool
        var terminationReason: String
        var covarianceMatrix: [[Double]]  // nParams × nParams
        var standardErrors: [Double]
        var rSquared: Double
        var adjustedRSquared: Double
        var reducedChiSquared: Double
    }

    // MARK: - Solve

    static func solve(
        dataX: [Double],
        dataY: [Double],
        weights: [Double]? = nil,
        initialParams: [Double],
        paramNames: [String],
        lowerBounds: [Double]? = nil,
        upperBounds: [Double]? = nil,
        expression: CompiledExpression,
        config: Config = Config()
    ) -> Result {

        let nData = dataX.count
        let nParams = initialParams.count
        let w = weights ?? Array(repeating: 1.0, count: nData)
        let lb = lowerBounds ?? Array(repeating: -Double.infinity, count: nParams)
        let ub = upperBounds ?? Array(repeating: Double.infinity, count: nParams)

        var p = initialParams
        var lambda = config.initialLambda
        var iter = 0
        var converged = false
        var reason = "Max iterations reached"

        // Helper: build parameter dict
        func paramDict(_ params: [Double]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: zip(paramNames, params))
        }

        // Helper: compute residuals (weighted)
        func residuals(_ params: [Double]) -> [Double] {
            let pd = paramDict(params)
            return (0..<nData).map { i in
                do {
                    let yhat = try expression.evaluate(x: dataX[i], parameters: pd)
                    return w[i] * (dataY[i] - yhat)
                } catch {
                    return 0.0   // treat as zero residual so RSS doesn't go NaN
                }
            }
        }

        // Helper: RSS
        func rss(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }

        // Helper: Jacobian (central finite differences)
        // eps must be large enough to produce a measurable change in the residuals.
        // When a parameter is near zero, we use an absolute step scaled to the
        // data range so the Jacobian column is never all-zeros due to underflow.
        let dataYRange = max(1.0, (dataY.max() ?? 1) - (dataY.min() ?? 0))
        let dataXRange = max(1.0, (dataX.max() ?? 1) - (dataX.min() ?? 0))
        let absoluteEps = config.finiteDiffEpsilon * max(dataYRange, dataXRange)

        func jacobian(_ params: [Double]) -> [[Double]] {
            var J = Array(repeating: Array(repeating: 0.0, count: nParams), count: nData)
            for j in 0..<nParams {
                // Use relative eps when param is large, absolute eps when near zero
                let eps = max(absoluteEps, abs(params[j]) * config.finiteDiffEpsilon)
                var pPlus = params; pPlus[j] += eps
                var pMinus = params; pMinus[j] -= eps
                let rPlus = residuals(pPlus)
                let rMinus = residuals(pMinus)
                for i in 0..<nData {
                    J[i][j] = (rPlus[i] - rMinus[i]) / (2.0 * eps)
                }
            }
            return J
        }

        // Helper: clamp to bounds
        func clamp(_ params: [Double]) -> [Double] {
            params.enumerated().map { (j, v) in min(ub[j], max(lb[j], v)) }
        }

        // Helper: J^T * J + lambda * diag(J^T * J)
        func jtj(_ J: [[Double]]) -> [[Double]] {
            var result = Array(repeating: Array(repeating: 0.0, count: nParams), count: nParams)
            for k in 0..<nParams {
                for l in 0..<nParams {
                    result[k][l] = (0..<nData).reduce(0.0) { $0 + J[$1][k] * J[$1][l] }
                }
            }
            return result
        }

        // Helper: J^T * r
        func jtr(_ J: [[Double]], _ r: [Double]) -> [Double] {
            (0..<nParams).map { k in (0..<nData).reduce(0.0) { $0 + J[$1][k] * r[$1] } }
        }

        // Helper: solve linear system A * x = b using Gaussian elimination with partial pivoting
        func solveLinear(_ A: [[Double]], _ b: [Double]) -> [Double]? {
            let n = b.count
            var mat = A.map { $0 + [0.0] }  // augmented matrix
            for i in 0..<n {
                mat[i][n] = b[i]
            }

            for col in 0..<n {
                // Partial pivot
                var maxRow = col
                var maxVal = abs(mat[col][col])
                for row in (col+1)..<n {
                    if abs(mat[row][col]) > maxVal { maxVal = abs(mat[row][col]); maxRow = row }
                }
                if maxVal < 1e-14 { return nil }
                mat.swapAt(col, maxRow)

                let pivot = mat[col][col]
                for row in (col+1)..<n {
                    let factor = mat[row][col] / pivot
                    for c in col...n { mat[row][c] -= factor * mat[col][c] }
                }
            }

            // Back substitution
            var x = Array(repeating: 0.0, count: n)
            for i in stride(from: n-1, through: 0, by: -1) {
                x[i] = mat[i][n]
                for j in (i+1)..<n { x[i] -= mat[i][j] * x[j] }
                x[i] /= mat[i][i]
            }
            return x
        }

        var currentResiduals = residuals(p)
        var currentRSS = rss(currentResiduals)

        // Track initial RSS for relative convergence checks
        let initialRSS = max(currentRSS, 1e-10)

        while iter < config.maxIterations {
            iter += 1
            let J = jacobian(p)
            let JTJ = jtj(J)
            let JTr = jtr(J, currentResiduals)

            // Build damped normal equations: (JTJ + λ·diag(JTJ)) δ = JTr
            var A = JTJ
            for k in 0..<nParams {
                A[k][k] += lambda * max(JTJ[k][k], 1e-10)
            }

            guard let delta = solveLinear(A, JTr) else {
                lambda *= config.lambdaUpFactor
                continue
            }


            // Subtract delta because our residuals are r=y-yhat (= -f), so JTr = -JTf
            let pNew = clamp(p.enumerated().map { (j, v) in v - delta[j] })
            let newResiduals = residuals(pNew)
            let newRSS = rss(newResiduals)

            // Acceptance test
            if newRSS < currentRSS {
                let improvement = (currentRSS - newRSS) / currentRSS
                p = pNew
                currentResiduals = newResiduals
                currentRSS = newRSS
                lambda /= config.lambdaDownFactor

                // Convergence checks only after minimum iterations
                if iter >= config.minIterations {
                    // Gradient convergence: JTr near zero relative to initial RSS
                    let gradNorm = JTr.map { abs($0) }.max() ?? 0
                    if gradNorm < config.gradientTolerance * initialRSS {
                        converged = true; reason = "Gradient convergence"; break
                    }
                    // Function convergence: RSS not improving meaningfully
                    if improvement < config.functionTolerance {
                        converged = true; reason = "Function value convergence"; break
                    }
                    // Step convergence: step tiny relative to initial RSS scale
                    let stepNorm = delta.map { abs($0) }.max() ?? 0
                    if stepNorm < config.stepTolerance * max(1.0, p.map { abs($0) }.max() ?? 1.0) {
                        converged = true; reason = "Step size convergence"; break
                    }
                }
            } else {
                lambda *= config.lambdaUpFactor
                if lambda > 1e16 {
                    reason = "Lambda too large — possible poor initial guess"
                    break
                }
            }
        }

        // MARK: Post-fit statistics

        let J = jacobian(p)
        let JTJ = jtj(J)

        // Covariance matrix: s² × (JTJ)⁻¹
        let dof = max(1, nData - nParams)
        let s2 = currentRSS / Double(dof)

        // Invert JTJ to get covariance
        var covMatrix = Array(repeating: Array(repeating: 0.0, count: nParams), count: nParams)
        if let invJTJ = invertMatrix(JTJ) {
            covMatrix = invJTJ.map { $0.map { $0 * s2 } }
        }

        let standardErrors = (0..<nParams).map { k in sqrt(max(0, covMatrix[k][k])) }

        // R²
        let yMean = dataY.reduce(0, +) / Double(nData)
        let ssTot = dataY.reduce(0) { $0 + ($1 - yMean) * ($1 - yMean) }
        let r2 = ssTot > 0 ? max(0, 1.0 - currentRSS / ssTot) : 1.0
        let adjR2 = 1.0 - (1.0 - r2) * Double(nData - 1) / Double(dof)
        let reducedChi2 = s2

        return Result(
            parameters: p,
            residuals: currentResiduals,
            jacobian: J,
            rss: currentRSS,
            iterations: iter,
            converged: converged,
            terminationReason: reason,
            covarianceMatrix: covMatrix,
            standardErrors: standardErrors,
            rSquared: r2,
            adjustedRSquared: adjR2,
            reducedChiSquared: reducedChi2
        )
    }

    // MARK: Matrix inversion via Gaussian elimination

    private static func invertMatrix(_ A: [[Double]]) -> [[Double]]? {
        let n = A.count
        // Augment with identity
        var mat = (0..<n).map { i in A[i] + (0..<n).map { j in i == j ? 1.0 : 0.0 } }

        for col in 0..<n {
            var maxRow = col
            var maxVal = abs(mat[col][col])
            for row in (col+1)..<n {
                if abs(mat[row][col]) > maxVal { maxVal = abs(mat[row][col]); maxRow = row }
            }
            if maxVal < 1e-14 { return nil }
            mat.swapAt(col, maxRow)
            let pivot = mat[col][col]
            for c in 0..<(2*n) { mat[col][c] /= pivot }
            for row in 0..<n where row != col {
                let factor = mat[row][col]
                for c in 0..<(2*n) { mat[row][c] -= factor * mat[col][c] }
            }
        }
        return mat.map { Array($0[n..<(2*n)]) }
    }
}
