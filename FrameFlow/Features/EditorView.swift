import SwiftUI
import SwiftData

private enum EditorMode: String, CaseIterable { case review = "选片", develop = "调色" }
private enum Tool: String, CaseIterable {
    case exposure = "曝光", highlights = "高光", shadows = "阴影", temperature = "色温", contrast = "对比度"
    var key: WritableKeyPath<Recipe, Double> {
        switch self {
        case .exposure: \.exposure
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .temperature: \.temperatureOffset
        case .contrast: \.contrast
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -3...3
        case .highlights, .shadows: 0...1
        case .temperature: -3000...3000
        case .contrast: 0.5...1.6
        }
    }
    var step: Double { self == .temperature ? 25 : 0.01 }
    var symbol: String {
        switch self {
        case .exposure: "plusminus"
        case .highlights: "sun.max"
        case .shadows: "moon"
        case .temperature: "thermometer.medium"
        case .contrast: "circle.lefthalf.filled"
        }
    }
}

private struct PreviewRequest: Equatable {
    let recipe: Recipe
    let original: Bool
    let edge: Int
}

struct EditorView: View {
    let photo: Photo
    let save: () -> Void
    var sequence = ReviewSequence()
    var navigate: (UUID) -> Void = { _ in }

    @SceneStorage("editor.mode") private var mode = EditorMode.review.rawValue
    @SceneStorage("editor.tool") private var toolName = Tool.exposure.rawValue
    @AppStorage("review.autoAdvance") private var autoAdvance = false
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var preview: CGImage?
    @State private var failure: String?
    @State private var showingOriginal = false
    @State private var comparing = false
    @State private var zoomed = false
    @State private var focus = false
    @State private var draft: Recipe?
    @State private var history = EditHistory()
    @State private var requests: AsyncStream<PreviewRequest>.Continuation?

    private var tool: Tool { Tool(rawValue: toolName) ?? .exposure }
    private var recipe: Recipe { draft ?? photo.recipe }
    private var request: PreviewRequest {
        PreviewRequest(recipe: comparing ? Recipe() : recipe, original: comparing,
                       edge: draft != nil ? 900 : (zoomed ? 3200 : 1600))
    }

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width > geometry.size.height && !typeSize.isAccessibilitySize
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                canvas
                if !focus {
                    ScrollView {
                        inspector
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .frame(width: sideBySide ? min(340, geometry.size.width * 0.44) : nil,
                           height: sideBySide ? nil : min(geometry.size.height * 0.52, inspectorHeight))
                    .background(.background)
                }
            }
        }
        .navigationTitle(photo.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: request) { _, value in requests?.yield(value) }
        .task(id: photo.local) { await displayPreviews() }
        .onDisappear { finishDrag() }
    }

    private var inspectorHeight: CGFloat {
        if typeSize.isAccessibilitySize { return .infinity }
        return mode == EditorMode.review.rawValue ? 212 : 266
    }

    private var canvas: some View {
        ZStack {
            Color(white: 0.055)
            if photo.local {
                PhotoCanvas(image: preview, move: stepPhoto, detail: { zoomed = $0 })
                if let failure {
                    Text(failure).font(.callout).foregroundStyle(.white)
                        .padding().background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                } else if preview == nil {
                    ProgressView().tint(.white)
                }
            } else {
                Label("原片已归档", systemImage: "archivebox").foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if showingOriginal {
                Text("原图").font(.caption.bold()).foregroundStyle(.white)
                    .padding(7).background(.black.opacity(0.75), in: Capsule()).padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                Button {
                    finishDrag()
                    comparing.toggle()
                } label: {
                    Image(systemName: "rectangle.on.rectangle.angled").frame(width: 44, height: 44)
                }
                .foregroundStyle(comparing ? .yellow : .white)
                .accessibilityLabel(comparing ? "查看调整后" : "查看原图")
                .disabled(!photo.local || photo.recipe == Recipe())
                Button { focus.toggle() } label: {
                    Image(systemName: focus ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(focus ? "显示工具" : "隐藏工具")
            }
            .foregroundStyle(.white).background(.black.opacity(0.68), in: Capsule()).padding(6)
        }
        .overlay(alignment: .bottom) {
            if sequence.ids.count > 1 {
                HStack(spacing: 0) {
                    pageButton(-1)
                    Text("\((sequence.index(of: photo.uuid) ?? 0) + 1) / \(sequence.ids.count)")
                        .font(.caption.monospacedDigit()).padding(.horizontal, 4)
                    pageButton(1)
                }
                .foregroundStyle(.white).background(.black.opacity(0.70), in: Capsule()).padding(6)
            }
        }
    }

    private func pageButton(_ offset: Int) -> some View {
        Button { stepPhoto(offset) } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right").frame(width: 44, height: 44)
        }
        .accessibilityLabel(offset < 0 ? "上一张" : "下一张")
        .keyboardShortcut(offset < 0 ? .leftArrow : .rightArrow, modifiers: [])
        .disabled(sequence.neighbor(of: photo.uuid, offset: offset) == nil)
    }

    private func stepPhoto(_ offset: Int) {
        guard let id = sequence.neighbor(of: photo.uuid, offset: offset) else { return }
        finishDrag()
        navigate(id)
    }

    private var inspector: some View {
        VStack(spacing: 8) {
            Picker("工作模式", selection: $mode) {
                ForEach(EditorMode.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("work-mode")
            .onChange(of: mode) { _, _ in finishDrag(); comparing = false }
            if mode == EditorMode.review.rawValue { review } else { develop }
        }
        .frame(maxWidth: .infinity)
    }

    private var review: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        let score = photo.rating == value ? 0 : value
                        mark { photo.rating = score }
                    } label: {
                        Image(systemName: photo.rating >= value ? "star.fill" : "star")
                            .foregroundStyle(photo.rating >= value ? Color.orange : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityLabel("评分 \(value) 星")
                    .accessibilityValue(photo.rating == value ? "已选" : "")
                    .accessibilityHint("再次选择相同星数可清除评分")
                    .keyboardShortcut(KeyEquivalent(Character(String(value))), modifiers: [])
                }
            }
            HStack {
                Button { mark { photo.favorite.toggle() } } label: {
                    Label("收藏", systemImage: photo.favorite ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .tint(photo.favorite ? .pink : .secondary)
                .keyboardShortcut("p", modifiers: [])
                Button { mark { photo.rejected.toggle() } } label: {
                    Label("淘汰", systemImage: photo.rejected ? "xmark.circle.fill" : "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .tint(photo.rejected ? .red : .secondary)
                .keyboardShortcut("x", modifiers: [])
            }
            .buttonStyle(.bordered)
            Toggle("标记后自动下一张", isOn: $autoAdvance)
                .font(.subheadline).frame(minHeight: 44)
        }
        .disabled(!photo.local)
    }

    private func mark(_ update: () -> Void) {
        guard photo.local else { return }
        update()
        photo.receipt = nil
        save()
        if autoAdvance { stepPhoto(1) }
    }

    private var develop: some View {
        VStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Tool.allCases, id: \.self) { item in
                        Button {
                            finishDrag()
                            toolName = item.rawValue
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: item.symbol)
                                Text(item.rawValue).font(.caption)
                            }
                            .padding(.horizontal, 7).frame(minWidth: 44, minHeight: 50)
                            .background(item == tool ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }
                        .foregroundStyle(item == tool ? Color.accentColor : Color.secondary)
                        .accessibilityAddTraits(item == tool ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
            HStack {
                Text(tool.rawValue)
                Spacer()
                Text(valueLabel).monospacedDigit()
                Button {
                    var reset = recipe
                    reset[keyPath: tool.key] = Recipe()[keyPath: tool.key]
                    commit(reset)
                } label: { Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44) }
                .accessibilityLabel("重置" + tool.rawValue)
                .disabled(recipe[keyPath: tool.key] == Recipe()[keyPath: tool.key])
            }.font(.subheadline)
            Slider(value: Binding(get: { recipe[keyPath: tool.key] }, set: { value in
                comparing = false
                var next = recipe
                next[keyPath: tool.key] = value
                draft = next
            }), in: tool.range, step: tool.step, onEditingChanged: { editing in if !editing { finishDrag() } })
            .accessibilityLabel(tool.rawValue)
            .accessibilityValue(valueLabel)
            .accessibilityAdjustableAction { direction in
                var next = recipe
                next[keyPath: tool.key] = min(tool.range.upperBound, max(tool.range.lowerBound,
                    next[keyPath: tool.key] + (direction == .increment ? tool.step : -tool.step)))
                commit(next)
            }
            HStack(spacing: 2) {
                Menu {
                    Button("相机默认") { commit(.init()) }
                    Button("柔和") { commit(.soft) }
                    Button("鲜明") { commit(.vivid) }
                } label: { Label("预设", systemImage: "slider.horizontal.3").frame(minHeight: 44) }
                .accessibilityIdentifier("presets")
                Spacer()
                Menu {
                    Picker("居中裁剪", selection: Binding(get: { recipe.crop }, set: { value in
                        var next = recipe
                        next.crop = value
                        commit(next)
                    })) {
                        ForEach(Crop.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "crop").frame(width: 44, height: 44) }
                .accessibilityLabel("居中裁剪")
                Button { if let p = history.undo(current: photo.recipe) { apply(p) } } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("undo-recipe")
                .accessibilityLabel("撤销").keyboardShortcut("z").disabled(!history.canUndo)
                Button { if let p = history.redo(current: photo.recipe) { apply(p) } } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("redo-recipe")
                .accessibilityLabel("重做").keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!history.canRedo)
            }
        }
        .disabled(!photo.local)
    }

    private var valueLabel: String {
        let value = recipe[keyPath: tool.key]
        if tool == .temperature { return String(format: "%+.0f K", value) }
        if tool == .exposure { return String(format: "%+.2f EV", value) }
        return String(format: "%.2f", value)
    }

    private func finishDrag() { if let draft { commit(draft) } }

    private func commit(_ next: Recipe) {
        history.record(from: photo.recipe, to: next)
        apply(next)
    }

    private func apply(_ next: Recipe) {
        draft = nil
        comparing = false
        guard photo.local, photo.recipe != next else { return }
        photo.recipe = next
        save()
    }

    private func displayPreviews() async {
        preview = nil
        failure = nil
        guard photo.local else { return }
        let url = LibraryFiles.raw(photo.uuid)
        let (stream, sink) = AsyncStream<PreviewRequest>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requests = sink
        sink.yield(request)
        defer { sink.finish() }
        if let thumb = try? await ThumbnailStore.shared.image(at: url), !Task.isCancelled { preview = thumb }
        var original: (edge: Int, image: CGImage)?
        for await item in stream {
            guard !Task.isCancelled else { break }
            do {
                let image: CGImage
                if item.recipe == Recipe(), let original, original.edge == item.edge {
                    image = original.image
                } else {
                    image = try await RAWRenderer.shared.preview(url, edits: item.recipe, longEdge: item.edge)
                    if item.recipe == Recipe() { original = (item.edge, image) }
                }
                guard !Task.isCancelled, item.original == comparing else { continue }
                preview = image
                showingOriginal = item.original
                failure = nil
            } catch {
                if !Task.isCancelled, item == request { failure = error.localizedDescription }
            }
        }
    }
}
