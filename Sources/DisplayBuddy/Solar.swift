import Foundation

/// Sunrise and sunset times for a location, using the NOAA approximation.
enum Solar {
    static func sunriseSunset(date: Date, latitude: Double, longitude: Double) -> (sunrise: Date, sunset: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dayOfYear = Double(Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1)
        let gamma = 2 * Double.pi / 365 * (dayOfYear - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let latRad = latitude * .pi / 180
        let zenith = 90.833 * Double.pi / 180
        let cosHA = cos(zenith) / (cos(latRad) * cos(decl)) - tan(latRad) * tan(decl)
        guard cosHA >= -1, cosHA <= 1 else { return nil } // polar day or night
        let ha = acos(cosHA) * 180 / .pi
        let sunriseMin = 720 - 4 * (longitude + ha) - eqTime
        let sunsetMin = 720 - 4 * (longitude - ha) - eqTime
        let localDay = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let midnightUTC = cal.date(from: localDay) else { return nil }
        return (midnightUTC.addingTimeInterval(sunriseMin * 60), midnightUTC.addingTimeInterval(sunsetMin * 60))
    }

    /// Rough location guess from the Mac's time zone, used until the user
    /// allows Location access. Good enough for sunrise/sunset within ~30 min.
    static func guessedLocation() -> (latitude: Double, longitude: Double) {
        let tz = TimeZone.current
        let longitude = Double(tz.secondsFromGMT() - (tz.isDaylightSavingTime() ? 3600 : 0)) / 3600 * 15
        return (45, longitude)
    }
}
