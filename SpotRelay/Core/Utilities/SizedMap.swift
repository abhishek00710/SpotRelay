import MapKit
import SwiftUI

struct SizedMap<Content: MapContent>: View {
    @Binding var position: MapCameraPosition
    let content: () -> Content
    @State private var shouldRenderMap = false
    @State private var renderTask: Task<Void, Never>?

    init(
        position: Binding<MapCameraPosition>,
        @MapContentBuilder content: @escaping () -> Content
    ) {
        _position = position
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let hasUsableSize = proxy.size.width > 20 && proxy.size.height > 20

            Group {
                if hasUsableSize && shouldRenderMap {
                    Map(position: $position, content: content)
                } else {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(SpotRelayTheme.surface)
                }
            }
            .task(id: hasUsableSize) {
                renderTask?.cancel()

                guard hasUsableSize else {
                    shouldRenderMap = false
                    return
                }

                renderTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    shouldRenderMap = true
                }
            }
            .onDisappear {
                renderTask?.cancel()
                renderTask = nil
                shouldRenderMap = false
            }
        }
    }
}
