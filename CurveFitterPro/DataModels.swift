import Foundation
import SwiftData

// MARK: - Data Point

struct DataPoint: Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var weight: Double = 1.0
    var isOutlier: Bool = false
}

// MARK: - Fit Parameter

struct FitParameter: Identifiable, Sendable {
    var id = UUID()
    var name: String
    var initialValue: Double
    var lowerBound: Double = -Double.infinity
    var upperBound: Double =  Double.infinity

    // Populated after fitting
    var fittedValue: Double?
    var standardError: Double?
    var confidenceIntervalLow: Double?
    var confidenceIntervalHigh: Double?

    var displayValue: String {
        guard let v = fittedValue else { return "—" }
        return String(format: "%.6g", v)
    }
    var displaySE: String {
        guard let se = standardError else { return "—" }
        return String(format: "%.6g", se)
    }
    var displayCI: String {
        guard let lo = confidenceIntervalLow, let hi = confidenceIntervalHigh else { return "—" }
        return "[\(String(format: "%.4g", lo)), \(String(format: "%.4g", hi))]"
    }
}

// MARK: - Fit Result

struct FitResult: Sendable {
    var parameters: [FitParameter]
    var rSquared: Double
    var adjustedRSquared: Double
    var residualSumOfSquares: Double
    var reducedChiSquared: Double
    var iterations: Int
    var converged: Bool
    var message: String
    var residuals: [Double] = []
    var fittedY: [Double] = []
    var covarianceMatrix: [[Double]] = []
}

// MARK: - Built-in Model

struct BuiltinModel: Identifiable {
    var id = UUID()
    var name: String
    var category: String
    var equation: String
    var expression: String
    var parameterNames: [String]
    var defaultValues: [Double]
    var description: String
    var typicalUseCase: String

    func makeParameters() -> [FitParameter] {
        zip(parameterNames, defaultValues).map { name, val in
            FitParameter(name: name, initialValue: val)
        }
    }
}

// MARK: - User-Saved Model

@Model
class UserModel {
    var id: UUID
    var name: String
    var expression: String
    var parameterNames: String   // comma-separated
    var defaultValues: Data      // [Double] as raw bytes
    var createdAt: Date
    var notes: String

    init(name: String, expression: String, parameterNames: [String],
         defaultValues: [Double], notes: String = "") {
        self.id = UUID()
        self.name = name
        self.expression = expression
        self.parameterNames = parameterNames.joined(separator: ",")
        self.defaultValues = doublesToData(defaultValues)
        self.createdAt = Date()
        self.notes = notes
    }

    var parameterNamesArray: [String] {
        parameterNames.split(separator: ",").map(String.init)
    }
    var defaultValuesArray: [Double] {
        dataToDoubles(defaultValues)
    }
}

// MARK: - Raw binary helpers
//
// Store arrays as raw IEEE-754 bytes. This works for any Double value
// including ±infinity and NaN, avoids all JSON encoding issues, and
// is fast (just a memcpy).

func doublesToData(_ values: [Double]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

func dataToDoubles(_ data: Data) -> [Double] {
    guard !data.isEmpty else { return [] }
    return data.withUnsafeBytes { ptr in
        Array(ptr.bindMemory(to: Double.self))
    }
}

func boolsToData(_ values: [Bool]) -> Data {
    Data(values.map { $0 ? UInt8(1) : UInt8(0) })
}

func dataToBools(_ data: Data) -> [Bool] {
    data.map { $0 != 0 }
}

// Nil-safe Double: store as two Doubles [isPresent, value]
// where isPresent is 1.0 if value exists, 0.0 if nil
func optionalDoublesToData(_ values: [Double?]) -> Data {
    var flat: [Double] = []
    flat.reserveCapacity(values.count * 2)
    for v in values {
        if let v = v { flat.append(1.0); flat.append(v) }
        else          { flat.append(0.0); flat.append(0.0) }
    }
    return doublesToData(flat)
}

func dataToOptionalDoubles(_ data: Data, count: Int) -> [Double?] {
    let flat = dataToDoubles(data)
    guard flat.count == count * 2 else { return Array(repeating: nil, count: count) }
    return (0..<count).map { i in
        flat[i * 2] != 0.0 ? flat[i * 2 + 1] : nil
    }
}

// MARK: - Project
//
// All stored properties are types CoreData/SwiftData can materialise:
// String, Int, Bool, Double, Date, Data.
// Arrays are stored as Data blobs using raw binary encoding above.

@Model
class Project {
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    var xLabel: String
    var yLabel: String
    var modelName: String
    var modelExpression: String
    var modelEquation: String

    var xAxisLog: Bool
    var yAxisLog: Bool
    var showConfidenceBand: Bool
    var showResiduals: Bool
    var confidenceLevel: Int

    // DataPoints stored as parallel Data blobs
    var dpXData:         Data = Data()
    var dpYData:         Data = Data()
    var dpWeightData:    Data = Data()
    var dpIsOutlierData: Data = Data()

    // Parameters stored as Data blobs + comma-separated names
    var paramNamesCSV:   String = ""
    var paramInitData:   Data = Data()
    var paramLowerData:  Data = Data()   // raw bytes: supports ±inf
    var paramUpperData:  Data = Data()
    var paramFittedData: Data = Data()   // optional encoding: [isPresent, value] pairs
    var paramSEData:     Data = Data()
    var paramCILowData:  Data = Data()
    var paramCIHighData: Data = Data()

    // FitResult stored as flat primitives + Data blobs
    var fitHasResult:   Bool   = false
    var fitRSquared:    Double = 0
    var fitAdjR2:       Double = 0
    var fitRSS:         Double = 0
    var fitChi2:        Double = 0
    var fitIterations:  Int    = 0
    var fitConverged:   Bool   = false
    var fitMessage:     String = ""
    var fitResidualsData: Data = Data()
    var fitFittedYData:   Data = Data()
    var fitCovData:       Data = Data()  // row-major nParams×nParams

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.xLabel = "X"
        self.yLabel = "Y"
        self.modelName = ""
        self.modelExpression = ""
        self.modelEquation = ""
        self.xAxisLog = false
        self.yAxisLog = false
        self.showConfidenceBand = true
        self.showResiduals = true
        self.confidenceLevel = 95
    }
}

// MARK: - Decode cache
//
// Avoids repeated blob decoding on every property access.
// Cache is keyed on the Data identity (pointer+length) so it
// invalidates automatically when the blob is replaced on write.

private var _dpCache:    (key: Data, value: [DataPoint])?    = nil
private var _paramCache: (key: Data, value: [FitParameter])? = nil

// MARK: - Project convenience accessors

extension Project {

    // MARK: DataPoints

    var dataPoints: [DataPoint] {
        get {
            // Use cached decode if the underlying blob hasn't changed
            if let c = _dpCache, c.key == dpXData { return c.value }
            let xs  = dataToDoubles(dpXData)
            let ys  = dataToDoubles(dpYData)
            let ws  = dataToDoubles(dpWeightData)
            let os  = dataToBools(dpIsOutlierData)
            guard !xs.isEmpty else { _dpCache = (dpXData, []); return [] }
            let points = xs.indices.map { i in
                DataPoint(
                    x:         xs[i],
                    y:         i < ys.count ? ys[i] : 0,
                    weight:    i < ws.count ? ws[i] : 1.0,
                    isOutlier: i < os.count ? os[i] : false
                )
            }
            _dpCache = (dpXData, points)
            return points
        }
        set {
            _dpCache        = nil   // invalidate cache
            dpXData         = doublesToData(newValue.map(\.x))
            dpYData         = doublesToData(newValue.map(\.y))
            dpWeightData    = doublesToData(newValue.map(\.weight))
            dpIsOutlierData = boolsToData(newValue.map(\.isOutlier))
            modifiedAt = Date()
        }
    }

    // MARK: Parameters

    var parameters: [FitParameter] {
        get {
            // Key on paramInitData as a proxy for the whole parameter set
            if let c = _paramCache, c.key == paramInitData { return c.value }
            let names   = paramNamesCSV.isEmpty ? [] : paramNamesCSV.split(separator: ",").map(String.init)
            let count   = names.count
            guard count > 0 else { _paramCache = (paramInitData, []); return [] }
            let initials = dataToDoubles(paramInitData)
            let lowers   = dataToDoubles(paramLowerData)
            let uppers   = dataToDoubles(paramUpperData)
            let fitted   = dataToOptionalDoubles(paramFittedData, count: count)
            let ses      = dataToOptionalDoubles(paramSEData,     count: count)
            let ciLows   = dataToOptionalDoubles(paramCILowData,  count: count)
            let ciHighs  = dataToOptionalDoubles(paramCIHighData, count: count)
            let params = names.indices.map { i in
                FitParameter(
                    name:                   names[i],
                    initialValue:           i < initials.count ? initials[i] : 1.0,
                    lowerBound:             i < lowers.count   ? lowers[i]   : -Double.infinity,
                    upperBound:             i < uppers.count   ? uppers[i]   :  Double.infinity,
                    fittedValue:            i < fitted.count   ? fitted[i]   : nil,
                    standardError:          i < ses.count      ? ses[i]      : nil,
                    confidenceIntervalLow:  i < ciLows.count   ? ciLows[i]   : nil,
                    confidenceIntervalHigh: i < ciHighs.count  ? ciHighs[i]  : nil
                )
            }
            _paramCache = (paramInitData, params)
            return params
        }
        set {
            _paramCache     = nil   // invalidate cache
            paramNamesCSV   = newValue.map(\.name).joined(separator: ",")
            paramInitData   = doublesToData(newValue.map(\.initialValue))
            paramLowerData  = doublesToData(newValue.map(\.lowerBound))
            paramUpperData  = doublesToData(newValue.map(\.upperBound))
            paramFittedData = optionalDoublesToData(newValue.map(\.fittedValue))
            paramSEData     = optionalDoublesToData(newValue.map(\.standardError))
            paramCILowData  = optionalDoublesToData(newValue.map(\.confidenceIntervalLow))
            paramCIHighData = optionalDoublesToData(newValue.map(\.confidenceIntervalHigh))
        }
    }

    // MARK: FitResult

    var fitResult: FitResult? {
        get {
            guard fitHasResult else { return nil }
            let n = paramNamesCSV.isEmpty ? 0 : paramNamesCSV.split(separator: ",").count
            var cov: [[Double]] = []
            let covFlat = dataToDoubles(fitCovData)
            if covFlat.count == n * n {
                cov = (0..<n).map { row in (0..<n).map { col in covFlat[row * n + col] } }
            }
            return FitResult(
                parameters:           parameters,        // uses cached decode above
                rSquared:             fitRSquared,
                adjustedRSquared:     fitAdjR2,
                residualSumOfSquares: fitRSS,
                reducedChiSquared:    fitChi2,
                iterations:           fitIterations,
                converged:            fitConverged,
                message:              fitMessage,
                residuals:            dataToDoubles(fitResidualsData),
                fittedY:              dataToDoubles(fitFittedYData),
                covarianceMatrix:     cov
            )
        }
        set {
            guard let r = newValue else { fitHasResult = false; return }
            fitHasResult      = true
            fitRSquared       = r.rSquared
            fitAdjR2          = r.adjustedRSquared
            fitRSS            = r.residualSumOfSquares
            fitChi2           = r.reducedChiSquared
            fitIterations     = r.iterations
            fitConverged      = r.converged
            fitMessage        = r.message
            fitResidualsData  = doublesToData(r.residuals)
            fitFittedYData    = doublesToData(r.fittedY)
            fitCovData        = doublesToData(r.covarianceMatrix.flatMap { $0 })
            modifiedAt        = Date()
            parameters        = r.parameters  // also invalidates _paramCache
        }
    }
}
