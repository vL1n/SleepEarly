import SwiftUI
import SwiftData

struct EditorView: View {
    let photo: Photo
    let save: () -> Void
    @Environment(\.horizontalSizeClass) private var width
    @State private var preview: CGImage?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            let layout = width == .regular ? AnyLayout(HStackLayout(alignment: .top)) : AnyLayout(VStackLayout())
            layout {
                ZStack {
                    Color.black
                    if !photo.local {
                        Label("原片已归档", systemImage: "archivebox")
                    } else if let failure {
                        Text(failure).padding()
                    } else if let preview {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .foregroundStyle(.white)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                adjustments
                    .frame(maxWidth: width == .regular ? 320 : .infinity)
            }
            .padding()
        }
        .navigationTitle(photo.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: PreviewKey(id: photo.uuid, recipe: photo.recipe, local: photo.local)) {
            failure = nil
            guard photo.local else { preview = nil; return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let image = try await RAWRenderer.shared.preview(LibraryFiles.raw(photo.uuid), edits: photo.recipe)
                try Task.checkCancellation()
                preview = image
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("显影").font(.headline)
                Spacer()
                Menu("预设") {
                    Button("相机默认") { change(.init()) }
                    Button("柔和") { change(.soft) }
                    Button("鲜明") { change(.vivid) }
                }
            }
            slider("曝光 EV", \.exposure, -3...3)
            slider("高光", \.highlights, 0...1)
            slider("阴影", \.shadows, 0...1)
            slider("色温偏移 K", \.temperatureOffset, -3000...3000)
            slider("对比度", \.contrast, 0.5...1.6)
            Picker("居中裁剪", selection: Binding(get: { photo.recipe.crop }, set: { value in
                var next = photo.recipe
                next.crop = value
                change(next)
            })) {
                ForEach(Crop.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Divider()
            Picker("评分", selection: Binding(get: { photo.rating }, set: { photo.rating = $0; markChanged() })) {
                ForEach(0...5, id: \.self) { Text("\($0) ★").tag($0) }
            }
            Toggle("收藏", isOn: Binding(get: { photo.favorite }, set: { photo.favorite = $0; markChanged() }))
            Toggle("淘汰", isOn: Binding(get: { photo.rejected }, set: { photo.rejected = $0; markChanged() }))
        }
        .disabled(!photo.local)
    }

    private func change(_ next: Recipe) {
        photo.recipe = next
        save()
    }

    private func markChanged() { photo.receipt = nil; save() }

    private func slider(_ title: String, _ key: WritableKeyPath<Recipe, Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(photo.recipe[keyPath: key], format: .number.precision(.fractionLength(key == \.temperatureOffset ? 0 : 2)))
                    .monospacedDigit()
            }.font(.caption)
            Slider(value: Binding(get: { photo.recipe[keyPath: key] }, set: { value in
                var next = photo.recipe
                next[keyPath: key] = value
                photo.recipe = next
            }), in: range, onEditingChanged: { editing in if !editing { save() } })
            .accessibilityLabel(title)
        }
    }
}

private struct PreviewKey: Equatable {
    let id: UUID
    let recipe: Recipe
    let local: Bool
}
