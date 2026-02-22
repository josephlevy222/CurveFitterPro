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

        // Solve A·x = b using LU decomposition.
        // Reuses the static LU helpers defined at the bottom of the class.
        func solveLinear(_ A: [[Double]], _ b: [Double]) -> [Double]? {
            guard let (L, U, piv) = LMSolver.luDecompose(A) else { return nil }
            // Apply the same permutation to b
            var pb = Array(repeating: 0.0, count: b.count)
            for i in 0..<b.count { pb[i] = b[piv[i]] }
            let y = LMSolver.forwardSolve(L, pb)
            return LMSolver.backSolve(U, y)
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

        // Covariance matrix: solve JᵀJ · C = s²·I column by column.
        //
        // This avoids explicitly forming (JᵀJ)⁻¹. We factor JᵀJ once into
        // P·A = L·U, then for each column j of the identity (scaled by s²)
        // we solve L·y = P·(s²·eⱼ) and U·x = y. The resulting x is the
        // j-th column of the covariance matrix. Numerically equivalent to
        // s² · (JᵀJ)⁻¹ but without the explicit inversion step.
        let dof = max(1, nData - nParams)
        let s2 = currentRSS / Double(dof)

        var covMatrix = Array(repeating: Array(repeating: 0.0, count: nParams), count: nParams)
        if let (L, U, piv) = LMSolver.luDecompose(JTJ) {
            // Condition check: large ratio of |U| diagonals → ill-conditioned
            let diagU = (0..<nParams).map { abs(U[$0][$0]) }
            let uMax = diagU.max() ?? 1
            let uMin = diagU.min() ?? 1
            let condProxy = uMax / max(uMin, 1e-300)
            // Even if ill-conditioned we proceed; large SEs will signal the problem
            _ = condProxy

            for col in 0..<nParams {
                // Build permuted s²·eⱼ: the col-th column of s²·I, permuted by P
                var b = Array(repeating: 0.0, count: nParams)
                for i in 0..<nParams { if piv[i] == col { b[i] = s2; break } }
                let y = LMSolver.forwardSolve(L, b)
                let x = LMSolver.backSolve(U, y)
                for row in 0..<nParams { covMatrix[row][col] = x[row] }
            }
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

    // MARK: LU decomposition with partial pivoting
    //
    // Factors A into P·A = L·U where P is a permutation, L is unit lower
    // triangular, and U is upper triangular.  Returns (L, U, pivot) or nil
    // if the matrix is singular.
    //
    // Advantages over Gauss-Jordan inversion:
    //   • More numerically stable for nearly-singular JᵀJ (correlated params)
    //   • Condition number is readable from the diagonal of U
    //   • The same factorisation can solve multiple right-hand sides cheaply

    static func luDecompose(_ A: [[Double]])
        -> (L: [[Double]], U: [[Double]], pivot: [Int])? {

        let n = A.count
        var U = A                                          // copy; will become U
        var L = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        var piv = Array(0..<n)                            // permutation indices

        for col in 0..<n {
            // Partial pivot: find row with largest absolute value in this column
            var maxVal = abs(U[col][col])
            var maxRow = col
            for row in (col+1)..<n {
                if abs(U[row][col]) > maxVal {
                    maxVal = abs(U[row][col])
                    maxRow = row
                }
            }
            // Singular or near-singular check
            if maxVal < 1e-14 { return nil }

            // Swap rows in U, L (columns already filled), and pivot index
            if maxRow != col {
                U.swapAt(col, maxRow)
                piv.swapAt(col, maxRow)
                // Swap already-computed L columns
                for k in 0..<col { let tmp = L[col][k]; L[col][k] = L[maxRow][k]; L[maxRow][k] = tmp }
            }

            L[col][col] = 1.0   // unit diagonal

            for row in (col+1)..<n {
                let factor = U[row][col] / U[col][col]
                L[row][col] = factor
                for c in col..<n { U[row][c] -= factor * U[col][c] }
            }
        }
        return (L, U, piv)
    }

    // Solve L·y = b (forward substitution, L is unit lower triangular)
    static func forwardSolve(_ L: [[Double]], _ b: [Double]) -> [Double] {
        let n = b.count
        var y = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            y[i] = b[i] - (0..<i).reduce(0.0) { $0 + L[i][$1] * y[$1] }
        }
        return y
    }

    // Solve U·x = y (back substitution, U is upper triangular)
    static func backSolve(_ U: [[Double]], _ y: [Double]) -> [Double] {
        let n = y.count
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n-1, through: 0, by: -1) {
            x[i] = (y[i] - ((i+1)..<n).reduce(0.0) { $0 + U[i][$1] * x[$1] }) / U[i][i]
        }
        return x
    }
}
