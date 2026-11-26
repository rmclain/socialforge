import SwiftUI
import SocialForgeKit

/// Settings › Publishing: your Meta app (Facebook Pages & Instagram), direct Instagram Login,
/// your Threads app, and public media storage.
struct MetaPublishingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var appID = ""
    @State private var appSecret = ""
    @State private var hasMetaSecret = false
    @State private var igAppID = ""
    @State private var igAppSecret = ""
    @State private var hasIGSecret = false
    @State private var threadsID = ""
    @State private var threadsSecret = ""
    @State private var hasThreadsSecret = false
    @State private var pasted = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var hasStorageAccess = false
    @State private var hasStorageSecret = false
    @State private var storageConfigured = false

    @AppStorage(MetaSettings.configKey) private var configID = ""
    @AppStorage(MetaSettings.redirectKey) private var redirect = Meta.desktopRedirect
    @AppStorage(MetaSettings.instagramRedirectKey) private var igRedirect = MetaSettings.defaultThreadsRedirect
    @AppStorage(MetaSettings.threadsRedirectKey) private var threadsRedirect = MetaSettings.defaultThreadsRedirect
    @AppStorage(PublicMediaSettings.endpointKey) private var endpoint = ""
    @AppStorage(PublicMediaSettings.bucketKey) private var bucket = ""
    @AppStorage(PublicMediaSettings.regionKey) private var region = "auto"
    @AppStorage(PublicMediaSettings.publicKey) private var publicBase = ""
    @AppStorage(PublicMediaSettings.styleKey) private var addressingStyle = S3AddressingStyle.auto.rawValue

    static let guide = URL(string: "https://github.com/rmclain/socialforge/blob/main/docs/META_SETUP.md")!

    var body: some View {
        SettingsGroup(title: "Your Meta app (Facebook Pages & linked Instagram)",
                      footer: "Publishes to Facebook Pages you manage (personal Facebook profiles are not supported by Meta's API) and linked Instagram professional accounts. Built from Meta's docs; not yet verified live.") {
            TextField("App ID", text: $appID).fieldStyle()
            SecureField(hasMetaSecret ? "App secret saved · paste to replace" : "App secret", text: $appSecret).fieldStyle()
            TextField("Login configuration ID (Facebook Login for Business, optional)", text: $configID).fieldStyle()
            TextField("Redirect URI", text: $redirect).fieldStyle().font(DS.mono)
            HStack {
                Button("Save to Keychain") { saveMeta() }.buttonStyle(SecondaryButtonStyle())
                if hasMetaSecret {
                    Button("Clear Secret") { clearMetaSecret() }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Connect Facebook & Instagram") {
                    saveMeta()
                    Task { await model.connectMeta(.facebook) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (appSecret.isEmpty && !hasMetaSecret))
                Spacer()
                Link("Setup guide", destination: Self.guide).font(DS.small)
            }
        }
        SettingsGroup(title: "Direct Instagram Business Login (optional)",
                      footer: "Connect an Instagram Business or Creator account directly via Instagram Login without needing a linked Facebook Page.") {
            TextField("Instagram App ID", text: $igAppID).fieldStyle()
            SecureField(hasIGSecret ? "Instagram App secret saved · paste to replace" : "Instagram App secret", text: $igAppSecret).fieldStyle()
            TextField("Redirect URI", text: $igRedirect).fieldStyle().font(DS.mono)
            HStack {
                Button("Save to Keychain") { saveInstagram() }.buttonStyle(SecondaryButtonStyle())
                if hasIGSecret {
                    Button("Clear Secret") { clearIGSecret() }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Connect Instagram Directly") {
                    saveInstagram()
                    Task { await model.connectMeta(.instagramLogin) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(igAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (igAppSecret.isEmpty && !hasIGSecret))
            }
        }
        SettingsGroup(title: "Your Threads app (standalone provider)",
                      footer: "Threads uses its own App ID, secret, and HTTPS redirect callback URL. Paste the full callback URL (including state) back into SocialForge to complete sign-in.") {
            TextField("Threads app ID", text: $threadsID).fieldStyle()
            SecureField(hasThreadsSecret ? "Threads app secret saved · paste to replace" : "Threads app secret", text: $threadsSecret).fieldStyle()
            TextField("Redirect URI", text: $threadsRedirect).fieldStyle().font(DS.mono)
            HStack {
                Button("Save to Keychain") { saveThreads() }.buttonStyle(SecondaryButtonStyle())
                if hasThreadsSecret {
                    Button("Clear Secret") { clearThreadsSecret() }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Connect Threads") {
                    saveThreads()
                    Task { await model.connectMeta(.threads) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(threadsID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (threadsSecret.isEmpty && !hasThreadsSecret))
            }
        }
        if let pending = model.pendingOAuth {
            SettingsGroup(title: "Finish connecting \(pending.serviceName)",
                          footer: "Copy the full redirect URL from your browser (including code and state) and paste it here. SocialForge validates state and redirect URI before exchanging the code.") {
                TextField("Paste the complete callback URL from your browser", text: $pasted).fieldStyle().font(DS.mono)
                    .onSubmit { finish() }
                HStack {
                    Button("Finish") { finish() }.buttonStyle(PrimaryButtonStyle()).disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { model.pendingOAuth = nil; pasted = "" }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        if let message = model.metaMessage {
            Text(message).font(DS.small).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
        }
        SettingsGroup(title: "Public media storage (S3 / Cloudflare R2)",
                      footer: "Required for Instagram photos/carousels and Threads photo/video posts. Files are stored under unpredictable keys and deleted automatically after publishing.") {
            TextField("S3 endpoint (https://<account>.r2.cloudflarestorage.com)", text: $endpoint).fieldStyle()
            HStack(spacing: Space.sm) {
                TextField("Bucket", text: $bucket).fieldStyle()
                TextField("Region", text: $region).fieldStyle().frame(width: 96)
                Picker("Style", selection: $addressingStyle) {
                    Text("Auto").tag(S3AddressingStyle.auto.rawValue)
                    Text("Path").tag(S3AddressingStyle.pathStyle.rawValue)
                    Text("Virtual").tag(S3AddressingStyle.virtualHosted.rawValue)
                }
                .labelsHidden()
                .frame(width: 92)
            }
            TextField("Public URL (https://pub-….r2.dev or your domain)", text: $publicBase).fieldStyle()
            TextField(hasStorageAccess ? "Access key ID saved · paste to replace" : "Access key ID", text: $accessKey).fieldStyle()
            SecureField(hasStorageSecret ? "Secret access key saved · paste to replace" : "Secret access key", text: $secretKey).fieldStyle()
            HStack {
                Button("Save Keys") { saveStorage() }.buttonStyle(SecondaryButtonStyle())
                if hasStorageAccess || hasStorageSecret {
                    Button("Clear Keys") { clearStorageKeys() }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Verify Storage") {
                    saveStorage()
                    Task { await model.testPublicMedia() }
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                StatusDot(
                    text: model.publicMediaVerification?.passed == true ? "Verified" : (storageConfigured ? "Configured · untested" : "Not configured"),
                    color: model.publicMediaVerification?.passed == true ? DS.green : (storageConfigured ? DS.amber : DS.text3)
                )
            }
        }
        .onAppear { reloadState() }
        .onChange(of: endpoint) { _, _ in refreshStorageFlag() }
        .onChange(of: bucket) { _, _ in refreshStorageFlag() }
        .onChange(of: region) { _, _ in refreshStorageFlag() }
        .onChange(of: publicBase) { _, _ in refreshStorageFlag() }
    }

    private func reloadState() {
        appID = Keychain.read(MetaSettings.appIDItem) ?? ""
        hasMetaSecret = Keychain.read(MetaSettings.secretItem)?.isEmpty == false
        igAppID = Keychain.read(MetaSettings.instagramIDItem) ?? ""
        hasIGSecret = Keychain.read(MetaSettings.instagramSecretItem)?.isEmpty == false
        threadsID = Keychain.read(MetaSettings.threadsIDItem) ?? ""
        hasThreadsSecret = Keychain.read(MetaSettings.threadsSecretItem)?.isEmpty == false
        hasStorageAccess = Keychain.read(PublicMediaSettings.accessKeyItem)?.isEmpty == false
        hasStorageSecret = Keychain.read(PublicMediaSettings.secretItem)?.isEmpty == false
        refreshStorageFlag()
    }

    private func refreshStorageFlag() {
        storageConfigured = PublicMediaSettings.config() != nil
    }

    private func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveMeta() {
        Keychain.write(MetaSettings.appIDItem, clean(appID))
        if !clean(appSecret).isEmpty { Keychain.write(MetaSettings.secretItem, clean(appSecret)); appSecret = "" }
        reloadState()
        model.modeRevision += 1
    }

    private func clearMetaSecret() {
        Keychain.write(MetaSettings.secretItem, "")
        appSecret = ""
        reloadState()
        model.modeRevision += 1
    }

    private func saveInstagram() {
        Keychain.write(MetaSettings.instagramIDItem, clean(igAppID))
        if !clean(igAppSecret).isEmpty { Keychain.write(MetaSettings.instagramSecretItem, clean(igAppSecret)); igAppSecret = "" }
        reloadState()
        model.modeRevision += 1
    }

    private func clearIGSecret() {
        Keychain.write(MetaSettings.instagramSecretItem, "")
        igAppSecret = ""
        reloadState()
        model.modeRevision += 1
    }

    private func saveThreads() {
        Keychain.write(MetaSettings.threadsIDItem, clean(threadsID))
        if !clean(threadsSecret).isEmpty { Keychain.write(MetaSettings.threadsSecretItem, clean(threadsSecret)); threadsSecret = "" }
        reloadState()
        model.modeRevision += 1
    }

    private func clearThreadsSecret() {
        Keychain.write(MetaSettings.threadsSecretItem, "")
        threadsSecret = ""
        reloadState()
        model.modeRevision += 1
    }

    private func saveStorage() {
        endpoint = clean(endpoint)
        bucket = clean(bucket)
        region = clean(region)
        publicBase = clean(publicBase)
        if !clean(accessKey).isEmpty { Keychain.write(PublicMediaSettings.accessKeyItem, clean(accessKey)); accessKey = "" }
        if !clean(secretKey).isEmpty { Keychain.write(PublicMediaSettings.secretItem, clean(secretKey)); secretKey = "" }
        model.publicMediaVerification = nil
        reloadState()
        model.modeRevision += 1
    }

    private func clearStorageKeys() {
        Keychain.write(PublicMediaSettings.accessKeyItem, "")
        Keychain.write(PublicMediaSettings.secretItem, "")
        accessKey = ""
        secretKey = ""
        model.publicMediaVerification = nil
        reloadState()
        model.modeRevision += 1
    }

    private func finish() {
        let text = pasted
        pasted = ""
        Task { await model.finishMeta(pasted: text) }
    }
}
