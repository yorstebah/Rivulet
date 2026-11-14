// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Trakt on iPhone and iPad: sign in with a code (the link opens Trakt's page with it filled in),
//  then which servers send what the viewer watches. Parity: tvOS `SettingsPageModels.trakt`,
//  Mac `MacTraktSettingsView`.

import SwiftUI

struct IOSTraktSettingsView: View {
    @ObservedObject private var account = TraktAccount.shared
    @State private var confirmSignOut = false
    @State private var scrobble: [MediaProviderKind: Bool] = [:]

    var body: some View {
        Form {
            switch account.state {
            case .signedOut:
                Section {
                    Button("Connect to Trakt") { account.startSignIn() }
                } footer: {
                    Text("Rivulet tells Trakt what you start, pause and finish, and adds Trakt’s picks to For You in Xtream films and series. Your Trakt sign-in is shared with your other devices through iCloud Sync.")
                }
            case .requestingCode:
                Section { ProgressView() }
            case .waiting(let code):
                Section {
                    LabeledContent("Code") {
                        Text(code.userCode).font(.title2.monospaced().bold()).textSelection(.enabled)
                    }
                    Link("Open Trakt", destination: code.activationURL)
                    Button("Cancel", role: .cancel) { account.cancelSignIn() }
                } footer: {
                    Text("Enter the code at \(code.verificationURL.absoluteString) and allow Rivulet. This page updates when you’re done.")
                }
            case .failed(let message):
                Section {
                    Button("Try Again") { account.startSignIn() }
                } footer: {
                    Text(message)
                }
            case .signedIn(let username):
                if !username.isEmpty {
                    Section { LabeledContent("Account", value: username) }
                }
                let kinds = TraktScrobbleSettings.setUpKinds
                if !kinds.isEmpty {
                    Section {
                        ForEach(kinds, id: \.rawValue) { kind in
                            Toggle(TraktScrobbleSettings.name(kind), isOn: Binding(
                                get: { scrobble[kind] ?? TraktScrobbleSettings.isOn(kind) },
                                set: { scrobble[kind] = $0; TraktScrobbleSettings.set($0, for: kind) }))
                        }
                    } header: {
                        Text("Send What You Watch")
                    } footer: {
                        Text("Turn a server off if it already reports to Trakt itself, or every play counts twice. Xtream series need a TMDB key to be recognised.")
                    }
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
            }
        }
        .navigationTitle("Trakt")
        .onAppear { account.refreshUsername() }
        .onDisappear {
            if case .waiting = account.state { return }
            if case .requestingCode = account.state { account.cancelSignIn() }
        }
        .confirmationDialog("Sign Out of Trakt?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            if CloudSync.shared.isSynced(accountID: TraktAccount.syncID) {
                Button("This Device Only", role: .destructive) { account.signOut(scope: .thisDevice) }
                Button("All Devices", role: .destructive) { account.signOut(scope: .everywhere) }
            } else {
                Button("Sign Out", role: .destructive) { account.signOut(scope: .everywhere) }
            }
        }
    }
}
