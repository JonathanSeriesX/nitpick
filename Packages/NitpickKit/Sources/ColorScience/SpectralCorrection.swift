import Foundation

/// Derives a colorimeter correction matrix from a display's spectra (Argyll .ccss) and the meter's own sensor curves.
///
/// The meter driver applies the returned matrix to raw sensor responses **instead of** the EEPROM factory matrix while
/// a spectral (CCSS) correction is active, so readings are XYZ for that display technology.
public enum SpectralCorrection {
    /// Least-squares 3×3 mapping the meter's raw sensor response to true CIE 1931 XYZ over `displaySamples`.
    ///
    /// - Parameters:
    ///   - sensorSensitivities: 3 rows (R, G, B sensor spectral sensitivities).
    ///   - displaySamples: n ≥ 3 display spectra (e.g. R, G, B, W).
    /// For each spectrum S, true XYZ = `CIEObserver.xyz(ofSpectrum:)` and sensor response_k = Σ S·sensor_k·Δλ, both on
    /// the 5 nm 380…780 nm grid. Returns nil for the wrong row counts or spectra that do not span 3D.
    public static func matrix(sensorSensitivities: SpectralSamples, displaySamples: SpectralSamples) -> Matrix3? {
        guard sensorSensitivities.rows.count == 3, displaySamples.rows.count >= 3 else { return nil }
        let sensors = sensorSensitivities.rows.map {
            CIEObserver.resampled($0, startWavelength: sensorSensitivities.startWavelength, step: sensorSensitivities.step)
        }
        var raw: [XYZ] = []
        var reference: [XYZ] = []
        for row in displaySamples.rows {
            let s = CIEObserver.resampled(row, startWavelength: displaySamples.startWavelength, step: displaySamples.step)
            let r = sensors.map { CIEObserver.integrate(s, $0) }
            raw.append(XYZ(X: r[0], Y: r[1], Z: r[2]))
            reference.append(CIEObserver.xyz(ofSpectrum: row, startWavelength: displaySamples.startWavelength, step: displaySamples.step))
        }
        return LinearAlgebra.leastSquaresMatrix(from: raw, to: reference)
    }
}
