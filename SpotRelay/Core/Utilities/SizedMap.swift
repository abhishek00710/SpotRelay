import MapKit
import SwiftUI

struct SizedMap<Content: MapContent>: View {
    @Binding var position: MapCameraPosition
    let content: () -> Content

    init(
        position: Binding<MapCameraPosition>,
        @MapContentBuilder content: @escaping () -> Content
    ) {
        _position = position
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width > 1, proxy.size.height > 1 {
                Map(position: $position, content: content)
            } else {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(SpotRelayTheme.surface)
            }
        }
    }
}
