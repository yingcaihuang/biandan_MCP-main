import Foundation
import MapKit

// MARK: - 识别出的地点 → 地图坐标
//
// 和检查器里「选地点」用同一套 MapKit 搜索（MKLocalSearch），不需要定位权限。查询词会发给 Apple 地图服务。
// 找到后坐标随任务写入地点字段（不开启地点提醒）。

enum PlaceLookup: Equatable, Sendable {
    case idle, locating, found, notFound
}

struct LocatedPlace: Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
}

@MainActor
enum PlaceLocator {
    /// 同一个查询词只搜一次（找不到也记下）；网络出错不记，下次还会重试。
    private static var cache: [String: LocatedPlace?] = [:]

    static func locate(_ query: String) async -> LocatedPlace? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let cached = cache[text] { return cached }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        // 聊天里的地点大多在国内：先按全国范围搜。
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35, longitude: 105),
                                            span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40))
        do {
            let response = try await MKLocalSearch(request: request).start()
            var found: LocatedPlace?
            if let item = response.mapItems.first {
                let coordinate = item.placemark.coordinate
                if CLLocationCoordinate2DIsValid(coordinate) {
                    found = LocatedPlace(name: item.name ?? text, latitude: coordinate.latitude,
                                         longitude: coordinate.longitude)
                }
            }
            cache.updateValue(found, forKey: text)
            return found
        } catch {
            // 没有结果时 MapKit 也会抛错（MKError.placemarkNotFound），当作找不到。
            if let mapError = error as? MKError, mapError.code == .placemarkNotFound {
                cache.updateValue(nil, forKey: text)
            }
            return nil
        }
    }

    nonisolated static func mapsURL(name: String, latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components?.url
    }
}
