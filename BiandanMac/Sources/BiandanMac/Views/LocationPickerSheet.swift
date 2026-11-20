import MapKit
import SwiftUI

/// 地图选出的地点。
struct PickedLocation: Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

/// 坐标文字的格式化和解析。未设置坐标在云端写成 -1, -1。
enum GeoText {
    static func format(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// 解析纬度、经度；为空、不是数字、超出范围或是 -1, -1 时返回 nil。
    static func coordinate(latitude: String, longitude: String) -> CLLocationCoordinate2D? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon), !(lat == -1 && lon == -1) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// 打开地图时的初始范围：有坐标时放大到附近，没有时显示全国。
    static func initialRegion(_ center: CLLocationCoordinate2D?) -> MKCoordinateRegion {
        if let center {
            return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.0, longitude: 105.0),
                                  span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40))
    }
}

/// 在地图上搜索或点击选点。选好后回填到检查器，由用户点「保存地点」写入云端。
struct LocationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (PickedLocation) -> Void

    @State private var query: String
    @State private var name: String
    @State private var pin: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchError: String?

    init(initialName: String, initial: CLLocationCoordinate2D?, onPick: @escaping (PickedLocation) -> Void) {
        self.onPick = onPick
        _query = State(initialValue: initialName)
        _name = State(initialValue: initialName)
        _pin = State(initialValue: initial)
        _position = State(initialValue: .region(GeoText.initialRegion(initial)))
    }

    var body: some View {
        ThemedSheet("在地图上选点", subtitle: "搜索地点或直接点击地图，选好后回到检查器点「保存地点」",
                    tag: ThemeTag(text: pin == nil ? "未选点" : "已选点", color: Theme.accent)) {
            HStack(spacing: 8) {
                TextField("", text: $query, prompt: Text("搜索地点，例如：公司、上海虹桥站"))
                    .themedField()
                    .onSubmit { search() }
                if searching { ProgressView().controlSize(.small) }
                Button("搜索") { search() }
                    .buttonStyle(.themed)
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let searchError {
                Text(searchError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.overdue)
            }
            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                            Button { choose(item) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "未命名地点")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Text(item.placemark.title ?? "")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.subtext)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 130)
                .themedCard()
            }

            MapReader { proxy in
                Map(position: $position) {
                    if let pin {
                        Marker(name.isEmpty ? "选定位置" : name, coordinate: pin)
                    }
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) { pin = coordinate }
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))

            InspectorSection("地点名称 · location") {
                TextField("", text: $name, prompt: Text("可留空"))
                    .themedField()
                    .padding(10)
            }
            ThemedRow("坐标 · latitude / longitude") {
                Text(verbatim: pin.map { GeoText.format($0.latitude) + ", " + GeoText.format($0.longitude) } ?? "点击地图选点")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(pin == nil ? Theme.subtext : Theme.text)
            }
            Text("中国大陆的 Apple 地图使用 GCJ-02 坐标，与便单一致，选到的坐标原样保存。海外地点为 WGS-84。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtext)
        } footer: {
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.themed)
                .keyboardShortcut(.cancelAction)
            Button("使用这个地点") {
                guard let pin else { return }
                onPick(PickedLocation(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                      latitude: pin.latitude, longitude: pin.longitude))
                dismiss()
            }
            .buttonStyle(.themedPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(pin == nil)
        }
        .frame(width: 580, height: 720)
    }

    private func choose(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        pin = coordinate
        if let title = item.name, !title.isEmpty { name = title }
        position = .region(GeoText.initialRegion(coordinate))
        results = []
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !searching else { return }
        searching = true
        searchError = nil
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = GeoText.initialRegion(pin)
        Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
                results = Array(response.mapItems.prefix(8))
                if results.isEmpty { searchError = "没有找到「\(text)」，可以直接点击地图选点。" }
            } catch {
                results = []
                searchError = "搜索失败：\(error.localizedDescription)"
            }
            searching = false
        }
    }
}
