import SwiftUI

struct PopoverView: View {
    @ObservedObject var janitor: Janitor
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            rules
            Divider()
            logSection
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Tidy").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Tidy now") { janitor.sweep() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Rename screenshots by the app they came from",
                   isOn: $janitor.renameScreenshots)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Sort Downloads into folders by kind", isOn: $janitor.sortDownloads)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))

            HStack(spacing: 6) {
                Toggle("Trash installers older than", isOn: $janitor.trashOldInstallers)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 11))
                Picker("", selection: $janitor.installerAgeDays) {
                    ForEach([1, 7, 14, 30], id: \.self) { Text("\($0)d").tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(!janitor.trashOldInstallers)
            }

            Text("Files are moved or trashed, never deleted. Unknown file types and "
                 + "part-finished downloads are left alone.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recently").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !janitor.log.isEmpty {
                    Button("Clear") { janitor.clearLog() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if janitor.log.isEmpty {
                Text("Nothing moved yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(janitor.log.prefix(6)) { action in
                    Text(action.text)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(action.text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
