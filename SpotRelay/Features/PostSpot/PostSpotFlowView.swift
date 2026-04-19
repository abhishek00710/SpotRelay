import MapKit
import SwiftUI

struct PostSpotFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var spotStore: SpotStore
    @State private var selectedMinutes = 2
    @State private var cameraPosition: MapCameraPosition = .automatic

    private let durations = [2, 5, 10]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Leaving soon?")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(SpotRelayTheme.textPrimary)

            Text("Share your spot in under three seconds.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SpotRelayTheme.textSecondary)

            HStack(spacing: 12) {
                ForEach(durations, id: \.self) { minute in
                    Button {
                        selectedMinutes = minute
                    } label: {
                        Text("\(minute) min")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                selectedMinutes == minute ? SpotRelayTheme.primary : SpotRelayTheme.surface,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                            .foregroundStyle(selectedMinutes == minute ? .white : SpotRelayTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            SizedMap(position: $cameraPosition) {
                UserAnnotation()
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .mapStyle(.standard(elevation: .flat))

            Button {
                spotStore.postSpot(durationMinutes: selectedMinutes)
                dismiss()
            } label: {
                Text("Share My Spot")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(SpotRelayTheme.heroGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
        .background(SpotRelayTheme.background)
        .task {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: spotStore.userCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )
            )
        }
    }
}
