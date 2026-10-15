import SwiftUI

struct ContentView: View {
    @Environment(QueueStore.self) private var store
    @State private var showCommand = false
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Backdrop()

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 14) {
                    HeaderBar()
                    QueueCard()
                }
                SettingsPanel()
                    .frame(width: 370)
            }
            .padding(.horizontal, 20)
            .padding(.top, 38)
            .padding(.bottom, 96)

            BottomToolbar(showCommand: $showCommand)
                .padding(.bottom, 22)

            if dropTargeted {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Theme.orange, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.orange.opacity(0.06)))
                    .overlay {
                        Label("Drop to add", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.orange))
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls: urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted }
        }
        .sheet(isPresented: $showCommand) { CommandSheet() }
        .onChange(of: store.settings) { store.persist() }
        .onChange(of: store.mode) { store.persist() }
        .task {
            await store.environment.refresh()
            store.reprobeAll()
        }
        .preferredColorScheme(.dark)
    }
}

/// Soft painted blobs behind the cards, a quiet nod to the colorful references.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.window
            Circle().fill(Theme.orange).frame(width: 420).blur(radius: 140).opacity(0.22).offset(x: -380, y: -260)
            Circle().fill(Theme.lilac).frame(width: 460).blur(radius: 150).opacity(0.18).offset(x: 420, y: 300)
            Circle().fill(Theme.green).frame(width: 360).blur(radius: 150).opacity(0.12).offset(x: -260, y: 360)
            Circle().fill(Theme.yellow).frame(width: 260).blur(radius: 130).opacity(0.10).offset(x: 300, y: -320)
        }
        .ignoresSafeArea()
    }
}
