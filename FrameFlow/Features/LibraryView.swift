import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum Operation { case open, jpeg, archive, clean }
private enum LibraryFilter: String, CaseIterable {
    case all = "全部", favorites = "收藏", rated = "4 星以上", rejects = "淘汰", local = "本地", archived = "已归档"
    func includes(_ p: Photo) -> Bool {
        switch self {
        case .all: true
        case .favorites: p.favorite
        case .rated: p.rating >= 4
        case .rejects: p.rejected
        case .local: p.local
        case .archived: p.receipt != nil
        }
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Photo.imported, order: .reverse) private var photos: [Photo]
    @SceneStorage("current-photo") private var activeID = ""
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var filter = LibraryFilter.all
    @State private var picking = false
    @State private var multi = false
    @State private var selected = Set<UUID>()
    @State private var copied: Recipe?
    @State private var operation = Operation.open
    @State private var confirmClean = false
    @State private var busy = false
    @State private var completed = 0
    @State private var total = 0
    @State private var notice: String?
    @State private var pending = Set<UUID>()
    @State private var reviewSequence = ReviewSequence()
    @State private var toast: String?
    @State private var toastID = UUID()
    @State private var stopAfterCurrent = false
    @State private var currentName = ""

    private var active: Photo? { photos.first { $0.uuid.uuidString == activeID } }
    private var targets: [Photo] {
        multi ? photos.filter { selected.contains($0.uuid) && $0.local } : [active].compactMap { $0 }.filter(\.local)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            VStack(spacing: 0) {
                if photos.isEmpty {
                    ContentUnavailableView {
                        Label("照片库为空", systemImage: "sdcard")
                    } description: {
                        Text("接入 SD 读卡器，在“文件”中选择 Sony ARW 原片。")
                    } actions: { Button("导入 ARW", action: { pick(.open) }).buttonStyle(.borderedProminent) }
                } else {
                    grid
                }
            }
            .navigationTitle("FrameFlow")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { batchMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(multi ? "完成" : "多选") { multi.toggle(); selected.removeAll() }.disabled(photos.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pick(.open) } label: { Label("导入 ARW", systemImage: "plus") }
                }
            }
        } detail: {
            if let active {
                EditorView(photo: active, save: save, sequence: reviewSequence) { next in
                    activeID = next.uuidString
                }
                    .id(active.uuid)
                    .onAppear {
                        if reviewSequence.index(of: active.uuid) == nil {
                            reviewSequence = ReviewSequence(photos.map(\.uuid))
                        }
                    }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { batchMenu } }
            } else {
                ContentUnavailableView("选择照片", systemImage: "camera.aperture")
            }
        }
        .disabled(busy)
        .safeAreaInset(edge: .bottom) {
            if busy {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(currentName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(completed) / \(total)").monospacedDigit()
                        Button(stopAfterCurrent ? "正在停止" : "完成本张后停止") { stopAfterCurrent = true }
                            .disabled(stopAfterCurrent)
                    }.font(.caption)
                    ProgressView(value: Double(completed), total: Double(max(1, total)))
                }.padding().background(.regularMaterial)
            } else if let toast {
                Text(toast).font(.subheadline).padding(10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
        .task(id: toastID) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
        .onChange(of: filter) { _, _ in selected.removeAll() }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: operation == .open ? [UTType(filenameExtension: "arw") ?? .rawImage] : [.folder],
                      allowsMultipleSelection: operation == .open) { result in
            do {
                let urls = try result.get()
                if !urls.isEmpty { start(urls) }
            } catch {
                if (error as NSError).code != NSUserCancelledError { notice = error.localizedDescription }
            }
        }
        .confirmationDialog("重新选择归档目录并校验后，移除所选照片的本地 ARW 副本？", isPresented: $confirmClean,
                            titleVisibility: .visible) {
            Button("选择目录并清理", role: .destructive) { pick(.clean) }
        }
        .alert("FrameFlow", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private var grid: some View {
        let visible = photos.filter(filter.includes)
        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(LibraryFilter.allCases, id: \.self) { item in
                        Button {
                            filter = item
                        } label: {
                            Text(item.rawValue).font(.subheadline.weight(item == filter ? .semibold : .regular))
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(item == filter ? Color.primary.opacity(0.12) : Color.clear, in: Capsule())
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden).padding(.horizontal, 8)
            HStack {
                Text(multi ? "已选 \(selected.count) 张" : "\(visible.count) 张照片")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if multi {
                    let ids = Set(visible.filter(\.local).map(\.uuid))
                    Button(selected == ids && !ids.isEmpty ? "取消全选" : "全选本地照片") {
                        selected = selected == ids ? [] : ids
                    }.disabled(ids.isEmpty)
                }
            }.font(.subheadline).padding(.horizontal, 12).frame(minHeight: multi ? 44 : 26)
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("没有符合筛选条件的照片", systemImage: "line.3.horizontal.decrease.circle")
                } actions: { Button("查看全部照片") { filter = .all } }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 102), spacing: 3)], spacing: 8) {
                        ForEach(visible) { photo in
                            Button {
                                if multi {
                                    if !selected.insert(photo.uuid).inserted { selected.remove(photo.uuid) }
                                } else {
                                    reviewSequence = ReviewSequence(visible.map(\.uuid))
                                    activeID = photo.uuid.uuidString
                                    compactColumn = .detail
                                }
                            } label: {
                                ThumbnailTile(photo: photo, checked: multi ? selected.contains(photo.uuid) : photo.uuid.uuidString == activeID)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("photo-" + photo.name)
                            .disabled(multi && !photo.local)
                            .contextMenu {
                                if photo.local {
                                    Button(photo.favorite ? "取消收藏" : "收藏", systemImage: "heart") {
                                        photo.favorite.toggle()
                                        photo.receipt = nil
                                        save()
                                    }
                                    Button(photo.rejected ? "取消淘汰" : "淘汰", systemImage: "xmark.circle") {
                                        photo.rejected.toggle()
                                        photo.receipt = nil
                                        save()
                                    }
                                    Menu("评星", systemImage: "star") {
                                        ForEach(0...5, id: \.self) { value in
                                            Button(value == 0 ? "清除评分" : "\(value) 星") {
                                                if photo.rating != value { photo.rating = value; photo.receipt = nil; save() }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 4)
                }
            }
        }
    }

    private func inform(_ message: String) {
        toast = message
        toastID = UUID()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private var batchMenu: some View {
        Menu {
            Button("复制当前照片参数") { copied = active?.recipe; inform("已复制调色参数") }.disabled(active == nil)
            Button("同步参数到所选照片") {
                if let copied {
                    let matching = targets
                    for photo in matching where photo.recipe != copied { photo.recipe = copied }
                    do { try context.save(); inform("已同步到 \(matching.count) 张照片") }
                    catch { notice = error.localizedDescription }
                }
            }.disabled(copied == nil || targets.isEmpty)
            Button("导出 JPEG…") { pick(.jpeg) }.disabled(targets.isEmpty)
            Button("归档 ARW、JPEG 与 JSON…") { pick(.archive) }.disabled(targets.isEmpty)
            Button("继续归档到上次目录") {
                do {
                    operation = .archive
                    pending = Set(targets.map(\.uuid))
                    start([try ArchiveBookmark.load()])
                } catch { notice = error.localizedDescription }
            }.disabled(targets.isEmpty)
            Button("清理已校验的本地副本…", role: .destructive) { confirmClean = true }
                .disabled(targets.isEmpty || targets.contains { $0.receipt == nil })
        } label: { Label("照片操作", systemImage: "ellipsis.circle") }
    }

    private func pick(_ action: Operation) {
        operation = action
        pending = Set(targets.map(\.uuid))
        picking = true
    }

    private func save() {
        do { try context.save() } catch { notice = error.localizedDescription }
    }

    private func start(_ urls: [URL]) {
        guard !busy else { return }
        let job = operation
        let items = photos.filter { pending.contains($0.uuid) }
        busy = true
        toast = nil
        stopAfterCurrent = false
        completed = 0
        total = job == .open ? urls.count : items.count
        Task { @MainActor in
            defer { busy = false }
            do {
                if job == .open {
                    for url in urls {
                        if stopAfterCurrent { break }
                        currentName = url.lastPathComponent
                        let id = UUID()
                        let sha = try await FileWorker.shared.importRAW(url, id: id)
                        let photo = Photo(id: id, name: url.lastPathComponent, sha: sha)
                        context.insert(photo)
                        do { try context.save() } catch {
                            context.delete(photo)
                            await FileWorker.shared.discardFailedImport(id)
                            throw error
                        }
                        completed += 1
                    }
                } else {
                    let root = urls[0]
                    for photo in items {
                        if stopAfterCurrent { break }
                        currentName = photo.name
                        switch job {
                        case .jpeg: try await FileWorker.shared.exportJPEG(photo.snapshot, to: root)
                        case .archive:
                            let receipt = try await FileWorker.shared.archive(photo.snapshot, to: root)
                            photo.receipt = try JSONEncoder().encode(receipt)
                        case .clean:
                            guard let data = photo.receipt else { throw FlowError("缺少归档记录") }
                            let receipt = try JSONDecoder().decode(ArchiveReceipt.self, from: data)
                            try await FileWorker.shared.clean(photo.snapshot, receipt: receipt, archiveRoot: root)
                            photo.local = false
                        case .open: break
                        }
                        try context.save()
                        completed += 1
                    }
                    if job == .archive { try ArchiveBookmark.save(root) }
                }
                inform(completed < total ? "已停止，完成 \(completed) / \(total) 张" : "已完成 \(completed) 张")
            } catch {
                notice = "已完成 \(completed) / \(total)。\n\(error.localizedDescription)"
            }
        }
    }
}

private struct ThumbnailTile: View {
    let photo: Photo
    let checked: Bool
    @State private var image: CGImage?
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.secondary.opacity(0.14).aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image, photo.local {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else if !photo.local || failed {
                        Image(systemName: photo.local ? "photo.badge.exclamationmark" : "archivebox")
                    } else { ProgressView() }
                }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if checked { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue).padding(4) }
                }
            Text(photo.name).font(.caption).lineLimit(1)
            HStack(spacing: 4) {
                if photo.rating > 0 { Label("\(photo.rating)", systemImage: "star.fill").foregroundStyle(.orange) }
                if photo.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                if photo.rejected { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
                if photo.receipt != nil { Image(systemName: "archivebox") }
            }.font(.caption2).frame(minHeight: 12)

        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.name)
        .accessibilityValue("\(photo.rating) 星" + (photo.favorite ? "，已收藏" : "") + (photo.rejected ? "，已淘汰" : ""))
        .accessibilityAddTraits(checked ? .isSelected : [])
        .task(id: photo.local) {
            image = nil
            failed = false
            guard photo.local else { return }
            do {
                let result = try await ThumbnailStore.shared.image(at: LibraryFiles.raw(photo.uuid))
                try Task.checkCancellation()
                image = result
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
