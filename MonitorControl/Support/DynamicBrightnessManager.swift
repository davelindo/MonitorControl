//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import CoreLocation
import os.log

final class DynamicBrightnessManager: NSObject, CLLocationManagerDelegate {
  static let shared = DynamicBrightnessManager()

  private enum Source {
    case ambientSensor
    case displayAmbientSensor
    case locationWeather
    case locationSun
  }

  private struct WeatherSample {
    let cloudCover: Double
    let date: Date
  }

  private struct OpenMeteoCurrent: Decodable {
    let cloud_cover: Double?
  }

  private struct OpenMeteoResponse: Decodable {
    let current: OpenMeteoCurrent?
  }

  private let queue = DispatchQueue(label: "DynamicBrightnessManager")
  private var timer: Timer?
  private var lastAppliedValue: Float?
  private var lastSource: Source?

  private var locationManager: CLLocationManager?
  private var lastLocation: CLLocation?
  private var lastLocationTimestamp: Date?
  private var lastWeatherSample: WeatherSample?
  private var lastWeatherFetch: Date?
  private var pendingWeatherTask: URLSessionDataTask?

  private let updateInterval: TimeInterval = 30
  private let weatherRefreshInterval: TimeInterval = 30 * 60
  private let locationRefreshInterval: TimeInterval = 10 * 60
  private let minBrightness: Float = 0.15
  private let maxBrightness: Float = 0.9
  private let smoothingFactor: Float = 0.35
  private let applyThreshold: Float = 0.01

  func updateEnabledState() {
    let shouldRun = prefs.bool(forKey: PrefKey.dynamicBrightnessEnabled.rawValue) && DisplayManager.shared.isLGActive()
    if shouldRun {
      self.startIfNeeded()
    } else {
      self.stop()
    }
  }

  func stop() {
    self.timer?.invalidate()
    self.timer = nil
    self.pendingWeatherTask?.cancel()
    self.pendingWeatherTask = nil
  }

  func refreshNow() {
    self.queue.async {
      self.refreshOnQueue()
    }
  }

  private func startIfNeeded() {
    guard self.timer == nil else {
      return
    }
    self.timer = Timer.scheduledTimer(withTimeInterval: self.updateInterval, repeats: true) { [weak self] _ in
      self?.refreshNow()
    }
    self.refreshNow()
  }

  private func refreshOnQueue() {
    guard prefs.bool(forKey: PrefKey.dynamicBrightnessEnabled.rawValue) else {
      return
    }
    guard DisplayManager.shared.isLGActive() else {
      return
    }
    guard app.sleepID == 0, app.reconfigureID == 0 else {
      return
    }
    guard let reading = self.currentTargetBrightness() else {
      return
    }

    let clamped = self.clamp(reading.value, min: self.minBrightness, max: self.maxBrightness)
    let smoothed = self.smoothedValue(for: clamped)
    let current = self.lastAppliedValue ?? smoothed
    guard abs(smoothed - current) >= self.applyThreshold else {
      return
    }

    let displays = DisplayManager.shared.getLGDisplays()
    guard !displays.isEmpty else {
      return
    }
    for display in displays where !display.readPrefAsBool(key: .isDisabled) {
      if display.readPrefAsBool(key: .unavailableDDC, for: .brightness) {
        continue
      }
      _ = display.setBrightness(smoothed)
    }
    self.lastAppliedValue = smoothed
    self.lastSource = reading.source
  }

  private func currentTargetBrightness() -> (value: Float, source: Source)? {
    if DisplayManager.shared.isBuiltInDisplayActive(), let brightness = self.readSystemBrightness() {
      return (brightness, .ambientSensor)
    }

    if let ratio = self.readDDCAmbientRatio() {
      let value = self.minBrightness + ratio * (self.maxBrightness - self.minBrightness)
      return (value, .displayAmbientSensor)
    }

    return self.locationBasedBrightness()
  }

  private func readDDCAmbientRatio() -> Float? {
    for display in DisplayManager.shared.getLGOtherDisplays() where !display.isSw() {
      if display.readPrefAsBool(key: .unavailableDDC, for: .ambientLightSensor) {
        continue
      }
      if let values = display.readDDCValues(for: .ambientLightSensor, tries: 1, minReplyDelay: nil), values.max > 0 {
        return Float(values.current) / Float(values.max)
      }
    }
    return nil
  }

  private func locationBasedBrightness() -> (value: Float, source: Source)? {
    let now = Date()
    if let lastLocationTimestamp, now.timeIntervalSince(lastLocationTimestamp) > self.locationRefreshInterval {
      self.requestLocationIfNeeded()
    } else if self.lastLocation == nil {
      self.requestLocationIfNeeded()
    }
    guard let location = self.lastLocation else {
      return nil
    }

    self.refreshWeatherIfNeeded(for: location)

    let elevation = SolarCalculator.solarElevation(date: now, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    var value = self.brightnessFromSunElevation(elevation)
    if let weather = self.lastWeatherSample, now.timeIntervalSince(weather.date) < self.weatherRefreshInterval {
      value = self.applyCloudCover(weather.cloudCover, to: value)
      return (value, .locationWeather)
    }
    return (value, .locationSun)
  }

  private func requestLocationIfNeeded() {
    if self.locationManager == nil {
      let manager = CLLocationManager()
      manager.delegate = self
      manager.desiredAccuracy = kCLLocationAccuracyKilometer
      self.locationManager = manager
    }
    guard let manager = self.locationManager else {
      return
    }
    let status = CLLocationManager.authorizationStatus()
    switch status {
    case .notDetermined:
      if #available(macOS 10.15, *) {
        manager.requestWhenInUseAuthorization()
      }
    case .authorizedAlways, .authorized:
      manager.requestLocation()
    default:
      break
    }
  }

  private func refreshWeatherIfNeeded(for location: CLLocation) {
    let now = Date()
    if let lastWeatherFetch, now.timeIntervalSince(lastWeatherFetch) < self.weatherRefreshInterval {
      return
    }
    let latitude = location.coordinate.latitude
    let longitude = location.coordinate.longitude
    guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=cloud_cover&timezone=auto") else {
      return
    }
    self.pendingWeatherTask?.cancel()
    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data else {
        return
      }
      let decoder = JSONDecoder()
      if let response = try? decoder.decode(OpenMeteoResponse.self, from: data), let cloudCover = response.current?.cloud_cover {
        self.queue.async {
          self.lastWeatherSample = WeatherSample(cloudCover: cloudCover, date: Date())
          self.lastWeatherFetch = Date()
          self.refreshOnQueue()
        }
      }
    }
    self.pendingWeatherTask = task
    self.lastWeatherFetch = now
    task.resume()
  }

  private func readSystemBrightness() -> Float? {
    if let builtIn = DisplayManager.shared.getBuiltInDisplay() as? AppleDisplay {
      return builtIn.getAppleBrightness()
    }
    return nil
  }

  private func brightnessFromSunElevation(_ elevation: Double) -> Float {
    let minAngle: Double = -6
    let maxAngle: Double = 60
    let clamped = min(max(elevation, minAngle), maxAngle)
    let normalized = Float((clamped - minAngle) / (maxAngle - minAngle))
    return self.minBrightness + normalized * (self.maxBrightness - self.minBrightness)
  }

  private func applyCloudCover(_ cover: Double, to value: Float) -> Float {
    let clampedCover = min(max(cover, 0), 100)
    let reduction = Float(clampedCover / 100.0) * 0.4
    let adjusted = value * (1 - reduction)
    return max(self.minBrightness, min(self.maxBrightness, adjusted))
  }

  private func clamp(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
  }

  private func smoothedValue(for target: Float) -> Float {
    guard let last = self.lastAppliedValue else {
      return target
    }
    return last + (target - last) * self.smoothingFactor
  }

  func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else {
      return
    }
    self.queue.async {
      self.lastLocation = location
      self.lastLocationTimestamp = Date()
      self.refreshOnQueue()
    }
  }

  func locationManager(_: CLLocationManager, didFailWithError error: Error) {
    os_log("Dynamic brightness location error: %{public}@", type: .info, String(describing: error))
  }

  @available(macOS 11.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = CLLocationManager.authorizationStatus()
    if status == .authorizedAlways || status == .authorized {
      manager.requestLocation()
    }
  }

  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    if status == .authorizedAlways || status == .authorized {
      manager.requestLocation()
    }
  }
}

private enum SolarCalculator {
  static func solarElevation(date: Date, latitude: Double, longitude: Double) -> Double {
    let calendar = Calendar(identifier: .gregorian)
    let utc = TimeZone(secondsFromGMT: 0) ?? .current
    let components = calendar.dateComponents(in: utc, from: date)
    guard let year = components.year,
          let month = components.month,
          let day = components.day,
          let hour = components.hour,
          let minute = components.minute,
          let second = components.second
    else {
      return 0
    }

    var y = year
    var m = month
    if m <= 2 {
      y -= 1
      m += 12
    }
    let a = floor(Double(y) / 100.0)
    let b = 2 - a + floor(a / 4.0)
    let dayFraction = (Double(hour) + Double(minute) / 60.0 + Double(second) / 3600.0) / 24.0
    let jd = floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + Double(day) + dayFraction + b - 1524.5
    let t = (jd - 2_451_545.0) / 36525.0

    let l0 = fmod(280.46646 + t * (36000.76983 + t * 0.0003032), 360.0)
    let mSun = 357.52911 + t * (35999.05029 - 0.0001537 * t)
    let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

    let c = sin(deg2rad(mSun)) * (1.914602 - t * (0.004817 + 0.000014 * t))
      + sin(self.deg2rad(2 * mSun)) * (0.019993 - 0.000101 * t)
      + sin(self.deg2rad(3 * mSun)) * 0.000289

    let trueLong = l0 + c
    let omega = 125.04 - 1934.136 * t
    let lambda = trueLong - 0.00569 - 0.00478 * sin(self.deg2rad(omega))
    let epsilon0 = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0
    let epsilon = epsilon0 + 0.00256 * cos(self.deg2rad(omega))
    let decl = asin(sin(deg2rad(epsilon)) * sin(self.deg2rad(lambda)))

    let yVar = pow(tan(deg2rad(epsilon / 2.0)), 2)
    let eqTime = 4 * self.rad2deg(
      yVar * sin(2 * self.deg2rad(l0))
        - 2 * e * sin(self.deg2rad(mSun))
        + 4 * e * yVar * sin(self.deg2rad(mSun)) * cos(2 * self.deg2rad(l0))
        - 0.5 * yVar * yVar * sin(4 * self.deg2rad(l0))
        - 1.25 * e * e * sin(2 * self.deg2rad(mSun))
    )

    let timezoneOffsetMinutes = Double(TimeZone.current.secondsFromGMT(for: date)) / 60.0
    let minutes = Double(hour) * 60.0 + Double(minute) + Double(second) / 60.0
    var trueSolarTime = minutes + eqTime + 4.0 * longitude - 60.0 * timezoneOffsetMinutes
    trueSolarTime = fmod(trueSolarTime, 1440.0)

    let hourAngle = (trueSolarTime / 4.0 < 0) ? (trueSolarTime / 4.0 + 180.0) : (trueSolarTime / 4.0 - 180.0)
    let cosZenith = sin(deg2rad(latitude)) * sin(decl) + cos(self.deg2rad(latitude)) * cos(decl) * cos(self.deg2rad(hourAngle))
    let zenith = acos(min(max(cosZenith, -1), 1))
    return 90.0 - self.rad2deg(zenith)
  }

  private static func deg2rad(_ degrees: Double) -> Double {
    degrees * Double.pi / 180.0
  }

  private static func rad2deg(_ radians: Double) -> Double {
    radians * 180.0 / Double.pi
  }
}
