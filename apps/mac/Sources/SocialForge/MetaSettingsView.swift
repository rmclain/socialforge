import SwiftUI
import SocialForgeKit

/// Settings › Publishing: your Meta app (Facebook Pages and Instagram), your Threads app, and public media storage.
struct MetaPublishingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var appID = ""
    @State private var appSecret = ""
    @State private var threadsID = ""
    @State private var threadsSecret = ""
    @State private var pasted = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @AppStorage(MetaSettings.configKey) private var configID = ""
    @AppStorage(MetaSettings.redirectKey) private var redirect = Meta.desktopRedirect
    @AppStorage(MetaSettings.threadsRedirectKey) private var threadsRedirect = MetaSettings.defaultThreadsRedirect
    @AppStorage(PublicMediaSettings.endpointKey) private var endpoint = ""
    @AppStorage(PublicMediaSettings.bucketKey) private var bucket = ""
    @AppStorage(PublicMediaSettings.regionKey) private var region = "auto"
    @AppStorage(PublicMediaSettings.publicKey) private var publicBase = ""

    static let guide = URL(string: "https://github.com/rmclain/socialforge/blob/main/docs/META_SETUP.md")!

    var body: some View {
        SettingsGroup(title: "Your Meta app (Facebook and Instagram)",
                      footer: "Create the app at developers.facebook.com and add your own Facebook account as its admin; in Development mode it posts to the Pages and Instagram professional accounts you manage. Add this redirect URI to Facebook Login's Valid OAuth Redirect URIs. Built from Meta's docs; not yet verified with a live post.") {
            TextField("App ID", text: $appID).fieldStyle()
            SecureField(Keychain.read(MetaSettings.secretItem)?.isEmpty == false ? "App secret saved · paste to replace" : "App secret", text: $appSecret).fieldStyle()
            TextField("Login configuration ID (Facebook Login for Business, optional)", text: $configID).fieldStyle()
            TextField("Redirect URI", text: $redirect).fieldStyle().font(DS.mono)
            HStack {
                Button("Save to Keychain") { saveMeta() }.buttonStyle(SecondaryButtonStyle())
                Button("Connect Facebook & Instagram") {
                    saveMeta()
                    Task { await model.connectMeta(.facebook) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(appID.isEmpty || (appSecret.isEmpty && Keychain.read(MetaSettings.secretItem)?.isEmpty != false))
                Spacer()
                Link("Setup guide", destination: Self.guide).font(DS.small)
            }
        }
        SettingsGroup(title: "Your Threads app",
                      footer: "Threads apps have their own ID and secret (the Threads use case in your Meta app). Threads accepts only https redirect URIs: register this one under Redirect Callback URLs. Its page never sees your secret; you paste the address back here.") {
            TextField("Threads app ID", text: $threadsID).fieldStyle()
            SecureField(Keychain.read(MetaSettings.threadsSecretItem)?.isEmpty == false ? "Threads app secret saved · paste to replace" : "Threads app secret", text: $threadsSecret).fieldStyle()
            TextField("Redirect URI", text: $threadsRedirect).fieldStyle().font(DS.mono)
            HStack {
                Button("Save to Keychain") { saveThreads() }.buttonStyle(SecondaryButtonStyle())
                Button("Connect Threads") {
                    saveThreads()
                    Task { await model.connectMeta(.threads) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(threadsID.isEmpty || (threadsSecret.isEmpty && Keychain.read(MetaSettings.threadsSecretItem)?.isEmpty != false))
            }
        }
        if let pending = model.pendingOAuth {
            SettingsGroup(title: "Finish connecting \(pending.serviceName)",
                          footer: "After you allow access, the browser lands on \(URL(string: pending.redirectURI)?.host() ?? "the redirect page"). Copy the whole address from the address bar and paste it here. The code in it works once, for a few minutes.") {
                TextField("Paste the address from your browser", text: $pasted).fieldStyle().font(DS.mono)
                    .onSubmit { finish() }
                HStack {
                    Button("Finish") { finish() }.buttonStyle(PrimaryButtonStyle()).disabled(pasted.isEmpty)
                    Button("Cancel") { model.pendingOAuth = nil; pasted = "" }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        if let message = model.metaMessage {
            Text(message).font(DS.small).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
        }
        SettingsGroup(title: "Public media storage (optional)",
                      footer: "Instagram photos and Threads photos and videos are fetched by Meta from a public address, so they need an S3-compatible bucket such as Cloudflare R2. Files go in a random folder and are deleted after the post goes out. Reels and Facebook posts upload from this Mac and don't need it. Keys stay in your Keychain.") {
            TextField("S3 endpoint (https://<account>.r2.cloudflarestorage.com)", text: $endpoint).fieldStyle()
            HStack(spacing: Space.sm) {
                TextField("Bucket", text: $bucket).fieldStyle()
                TextField("Region", text: $region).fieldStyle().frame(width: 96)
            }
            TextField("Public URL (https://pub-….r2.dev or your domain)", text: $publicBase).fieldStyle()
            TextField(Keychain.read(PublicMediaSettings.accessKeyItem)?.isEmpty == false ? "Access key ID saved · paste to replace" : "Access key ID", text: $accessKey).fieldStyle()
            SecureField(Keychain.read(PublicMediaSettings.secretItem)?.isEmpty == false ? "Secret access key saved · paste to replace" : "Secret access key", text: $secretKey).fieldStyle()
            HStack {
                Button("Save Keys") { saveStorage() }.buttonStyle(SecondaryButtonStyle())
                Button("Test Upload") {
                    saveStorage()
                    Task { await model.testPublicMedia() }
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                StatusDot(text: PublicMediaSettings.config == nil ? "Not set up" : "Set up", color: PublicMediaSettings.config == nil ? DS.text3 : DS.green)
            }
        }
        .onAppear {
            appID = Keychain.read(MetaSettings.appIDItem) ?? ""
            threadsID = Keychain.read(MetaSettings.threadsIDItem) ?? ""
        }
    }

    private func saveMeta() {
        Keychain.write(MetaSettings.appIDItem, appID.trimmingCharacters(in: .whitespaces))
        if !appSecret.isEmpty { Keychain.write(MetaSettings.secretItem, appSecret.trimmingCharacters(in: .whitespaces)); appSecret = "" }
    }

    private func saveThreads() {
        Keychain.write(MetaSettings.threadsIDItem, threadsID.trimmingCharacters(in: .whitespaces))
        if !threadsSecret.isEmpty { Keychain.write(MetaSettings.threadsSecretItem, threadsSecret.trimmingCharacters(in: .whitespaces)); threadsSecret = "" }
    }

    private func saveStorage() {
        if !accessKey.isEmpty { Keychain.write(PublicMediaSettings.accessKeyItem, accessKey.trimmingCharacters(in: .whitespaces)); accessKey = "" }
        if !secretKey.isEmpty { Keychain.write(PublicMediaSettings.secretItem, secretKey.trimmingCharacters(in: .whitespaces)); secretKey = "" }
    }

    private func finish() {
        let text = pasted
        pasted = ""
        Task { await model.finishMeta(pasted: text) }
    }
}
