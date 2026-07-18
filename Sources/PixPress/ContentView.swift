import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        HSplitView {
            settingsPanel
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
            mainPanel
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    // MARK: Settings panel

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Réglages")
                    .font(.title3.bold())

                // Format
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format de sortie").font(.subheadline.weight(.medium))
                    Picker("", selection: $model.format) {
                        ForEach(OutputFormat.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                // Lossless (webp only)
                if model.format.supportsLossless {
                    Toggle("Sans perte (lossless)", isOn: $model.lossless)
                        .toggleStyle(.switch)
                }

                // Quality
                if model.format.usesQuality && !(model.format == .webp && model.lossless) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Qualité").font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(model.quality))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.quality, in: 1...100, step: 1)
                    }
                } else if model.format == .png {
                    Text("PNG : ré-encodage sans perte (métadonnées supprimées). Pour réduire fortement le poids, convertissez en WebP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Resize
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Redimensionner", isOn: $model.resizeEnabled)
                        .toggleStyle(.switch)
                    if model.resizeEnabled {
                        HStack {
                            Text("Côté max")
                            Spacer()
                            TextField("", value: $model.maxDimension, format: .number)
                                .frame(width: 70)
                                .multilineTextAlignment(.trailing)
                            Text("px").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }

                Divider()

                // Destination
                VStack(alignment: .leading, spacing: 6) {
                    Text("Destination").font(.subheadline.weight(.medium))
                    Picker("", selection: $model.outputMode) {
                        ForEach(model.availableOutputModes) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    if model.outputMode == .overwriteOriginal {
                        Label("Les originaux seront remplacés (irréversible). Les conversions vers un autre format sont écrites à côté.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if model.outputMode == .chooseFolder {
                        HStack(spacing: 6) {
                            Text(model.outputFolder?.lastPathComponent ?? "Aucun dossier")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choisir…") { model.chooseOutputFolder() }
                                .controlSize(.small)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    model.recompressAll()
                } label: {
                    Label("Recompresser tout", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(model.items.isEmpty)
            }
            .padding(18)
        }
        .background(.background)
    }

    // MARK: Main panel

    private var mainPanel: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                dropZone
            } else {
                itemList
                Divider()
                bottomBar
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Glissez vos images ici")
                .font(.title2.weight(.medium))
            Text("JPEG · PNG · WebP · HEIC · AVIF — traitement par lot")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Ajouter des fichiers…") { model.openFilePicker() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    ItemRow(item: item) { model.removeItem(id: item.id) }
                    Divider()
                }
            }
        }
    }

    private var bottomBar: some View {
        let stats = model.stats
        return HStack(spacing: 12) {
            Button {
                model.openFilePicker()
            } label: {
                Label("Ajouter", systemImage: "plus")
            }

            Button(role: .destructive) {
                model.clear()
            } label: {
                Label("Vider", systemImage: "trash")
            }

            Spacer()

            if let saved = stats.savings {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(formatBytes(stats.original)) → \(formatBytes(stats.new))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "−%.0f %% au total", saved * 100))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(saved > 0 ? .green : .secondary)
                }
            }

            Button {
                let n = model.saveAll()
                notifySaved(n)
            } label: {
                Label("Enregistrer tout", systemImage: "square.and.arrow.down")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut("s")
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || !model.items.contains { $0.resultData != nil })
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.addURLs(urls)
        }
        return true
    }

    private func notifySaved(_ n: Int) {
        guard n > 0 else { return }
        let a = NSAlert()
        a.messageText = n == 1 ? "1 image enregistrée" : "\(n) images enregistrées"
        switch model.outputMode {
        case .besideOriginal:
            a.informativeText = "Les fichiers ont été écrits à côté des originaux."
        case .overwriteOriginal:
            a.informativeText = "Les originaux ont été remplacés (les conversions de format ont été écrites à côté)."
        case .chooseFolder:
            a.informativeText = "Les fichiers ont été écrits dans le dossier choisi."
        }
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// MARK: - Row

struct ItemRow: View {
    let item: ImageItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .font(.system(.body, design: .default).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                sizeLine
            }
            Spacer()
            statusView
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.15))
            if let t = item.thumbnail {
                Image(nsImage: t)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 46, height: 46)
    }

    @ViewBuilder
    private var sizeLine: some View {
        HStack(spacing: 6) {
            if let newSize = item.newSize {
                Text(formatBytes(item.originalSize))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(formatBytes(newSize))
                    .fontWeight(.medium)
                if let ext = item.outputFormat?.fileExtension {
                    Text(ext.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            } else {
                Text(formatBytes(item.originalSize)).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.tertiary)
        case .processing:
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 8) {
                if let r = item.savingsRatio {
                    Text(String(format: "%+.0f %%", -r * 100))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(r > 0 ? .green : .orange)
                }
                if item.savedURL != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        case .failed(let msg):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(msg)
        }
    }
}
