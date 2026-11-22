import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum Operation { case open, jpeg, archive, clean }
private enum LibraryFilter: String, CaseIterable {
    case all = "全部", favorites = "收藏", rejects = "淘汰", local = "本地", archived = "已归档"
    func includes(_ p: Photo) -> Bool {
        switch self {
        case .all: true
        case .favorites: p.favorite
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
    @State private var pending = [UUID]()

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
                    Button(multi ? "完成" : "多选") { multi.toggle(); selected.removeAll() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pick(.open) } label: { Label("导入 ARW", systemImage: "plus") }
                }
            }
        } detail: {
            if let active {
                EditorView(photo: active, save: save).id(active.uuid)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { batchMenu } }
            } else {
                ContentUnavailableView("选择照片", systemImage: "camera.aperture")
            }
        }
        .disabled(busy)
        .safeAreaInset(edge: .bottom) {
            if busy {
                ProgressView("正在处理 \(completed) / \(total)", value: Double(completed), total: Double(max(1, total)))
                    .padding().background(.regularMaterial)
            }
        }
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
        ScrollView {
            HStack {
                Picker("筛选", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Spacer()
                Text(multi ? "已选 \(selected.count)" : "\(photos.filter(filter.includes).count) 张")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 5)], spacing: 10) {
                ForEach(photos.filter(filter.includes)) { photo in
                    Button {
                        if multi {
                            if !selected.insert(photo.uuid).inserted { selected.remove(photo.uuid) }
                        } else {
                            activeID = photo.uuid.uuidString
                            compactColumn = .detail
                        }
                    } label: {
                        ThumbnailTile(photo: photo, checked: multi ? selected.contains(photo.uuid) : photo.uuid.uuidString == activeID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }.contentMargins(.horizontal, 10, for: .scrollContent)
    }

    private var batchMenu: some View {
        Menu {
            Button("复制当前照片参数") { copied = active?.recipe }.disabled(active == nil)
            Button("同步参数到所选照片") {
                if let copied { for photo in targets { photo.recipe = copied }; save() }
            }.disabled(copied == nil || targets.isEmpty)
            Button("导出 JPEG…") { pick(.jpeg) }.disabled(targets.isEmpty)
            Button("归档 ARW、JPEG 与 JSON…") { pick(.archive) }.disabled(targets.isEmpty)
            Button("继续归档到上次目录") {
                do {
                    operation = .archive
                    pending = targets.map(\.uuid)
                    start([try ArchiveBookmark.load()])
                } catch { notice = error.localizedDescription }
            }.disabled(targets.isEmpty)
            Button("清理已校验的本地副本…", role: .destructive) { confirmClean = true }
                .disabled(targets.isEmpty || targets.contains { $0.receipt == nil })
        } label: { Label("照片操作", systemImage: "ellipsis.circle") }
    }

    private func pick(_ action: Operation) {
        operation = action
        pending = targets.map(\.uuid)
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
        completed = 0
        total = job == .open ? urls.count : items.count
        Task { @MainActor in
            defer { busy = false }
            do {
                if job == .open {
                    for url in urls {
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
                notice = "已完成 \(completed) 张。"
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
            Text("\(photo.rating) ★  \(photo.favorite ? "♥" : "") \(photo.rejected ? "淘汰" : "")")
                .font(.caption2).foregroundStyle(.secondary)
        }
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
