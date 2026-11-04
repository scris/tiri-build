import SwiftUI
import TiriCore

enum RepositoryTransfer {
    case fetching, pulling, pushing

    var title: String {
        switch self {
        case .fetching: "Fetching"
        case .pulling: "Pulling"
        case .pushing: "Pushing"
        }
    }
}

/// The bar along the bottom of the window, when it has something to say.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.languageRevision
        if model.statusBarHasContent {
            bar
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(model.repositories) { repository in
                            RepositoryStatusItem(repository: repository, showsName: model.repositories.count > 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                LanguageStatusItem()
                    .fixedSize()
                    .padding(.trailing, 16)
            }
            .frame(height: 25)
        }
    }
}

/// One repository: where it stands, and fetch, pull and push.
struct RepositoryStatusItem: View {
    let repository: RepositoryStatus
    let showsName: Bool
    @Environment(AppModel.self) private var model

    private var transfer: RepositoryTransfer? { model.repositoryTransfers[repository.root] }

    private var summary: String {
        var lines = [repository.branch.map { "On \($0)" } ?? "Not on a branch"]
        if let upstream = repository.upstream { lines.append("Tracks \(upstream)") }
        if repository.isDirty { lines.append("Has uncommitted changes") }
        lines.append((repository.root as NSString).abbreviatingWithTildeInPath)
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(repository.title + (repository.isDirty ? "*" : ""))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)
                if showsName {
                    Text(repository.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help(summary)
            if repository.remote != nil {
                controls
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var controls: some View {
        if let transfer {
            ProgressView().controlSize(.mini)
            Text(transfer.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Button { model.fetch(repository) } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Fetch from \(repository.remote ?? "the remote")")
            .accessibilityLabel("Fetch")
            if repository.canPublish {
                Button("Publish") { model.confirmPush(repository) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .help("Push this branch to \(repository.remote ?? "the remote") for the first time")
            } else if repository.upstream != nil {
                count(repository.behind, arrow: "↓", label: "Pull",
                      help: repository.behind > 0 ? "Pull from \(repository.upstream ?? "the remote")" : "Nothing to pull, as of the last fetch") {
                    model.pull(repository)
                }
                count(repository.ahead, arrow: "↑", label: "Push",
                      help: repository.ahead > 0 ? "Push to \(repository.upstream ?? "the remote")" : "Nothing to push") {
                    model.confirmPush(repository)
                }
            }
        }
    }

    private func count(_ value: Int, arrow: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(value)\(arrow)")
                .font(.system(size: 11, weight: value > 0 ? .medium : .regular).monospacedDigit())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(value > 0 ? Color.accentColor : Color.secondary.opacity(0.5))
        .disabled(value == 0)
        .help(help)
        .accessibilityLabel(label)
    }
}
