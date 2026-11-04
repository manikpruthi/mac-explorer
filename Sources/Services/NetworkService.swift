import AppKit
import Foundation
import Network

@MainActor
final class SMBDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var retained: Set<NetService> = []
    private var pending: Set<ObjectIdentifier> = []
    private var resolvedServers: [NetworkServer] = []
    private var resolveContinuation: CheckedContinuation<[NetworkServer], Never>?
    private var browseContinuation: CheckedContinuation<Void, Never>?
    private var browseError: String?

    func discover(limit: Int = 6) async -> (servers: [NetworkServer], error: String?) {
        await browse(timeout: 1.6)
        let selected = Array(services.prefix(limit))
        let resolved = await resolveAll(selected)
        return (resolved, browseError)
    }

    private func resolveAll(_ selected: [NetService]) async -> [NetworkServer] {
        guard !selected.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            resolveContinuation = continuation
            pending = []
            resolvedServers = []
            for service in selected {
                retained.insert(service)
                pending.insert(ObjectIdentifier(service))
                service.delegate = self
                service.resolve(withTimeout: 1.4)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                for service in selected {
                    self.finishResolve(service, host: service.hostName, port: service.port)
                }
            }
        }
    }

    private func browse(timeout: TimeInterval) async {
        await withCheckedContinuation { continuation in
            browseContinuation = continuation
            services = []
            let browser = NetServiceBrowser()
            self.browser = browser
            browser.delegate = self
            browser.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finishBrowse()
            }
        }
    }

    private func finishBrowse() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        if let continuation = browseContinuation {
            browseContinuation = nil
            continuation.resume()
        }
    }

    private func finishResolve(_ service: NetService, host: String?, port: Int) {
        let key = ObjectIdentifier(service)
        guard pending.remove(key) != nil else { return }
        let resolvedHost: String = {
            guard let host, !host.isEmpty else { return service.name }
            return host.hasSuffix(".") ? String(host.dropLast()) : host
        }()
        let server = NetworkServer(
            name: service.name,
            host: resolvedHost,
            port: port > 0 ? port : nil
        )
        service.delegate = nil
        retained.remove(service)
        resolvedServers.append(server)
        if pending.isEmpty, let continuation = resolveContinuation {
            resolveContinuation = nil
            continuation.resume(returning: resolvedServers)
        }
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if !services.contains(where: { $0.name == service.name }) {
            services.append(service)
            retained.insert(service)
        }
        if services.count >= 6 {
            finishBrowse()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        browseError = "Local network discovery is unavailable."
        finishBrowse()
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        finishResolve(sender, host: sender.hostName, port: sender.port)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finishResolve(sender, host: nil, port: 0)
    }
}

enum NetworkService {
    @MainActor
    static func state() async -> NetworkState {
        let mounted = mountedShares()
        let discovery = SMBDiscovery()
        let (servers, error) = await discovery.discover()
        return NetworkState(servers: servers, mounted: mounted, error: error)
    }

    static func mountedShares() -> [MountedShare] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTypeNameKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) else {
            return []
        }
        var shares: [MountedShare] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let fsType = (values.volumeTypeName ?? "").lowercased()
            guard fsType.contains("smbfs") || fsType.contains("afpfs") || fsType.contains("nfs") || fsType.contains("webdav") else {
                continue
            }
            let mountPath = url.path
            shares.append(MountedShare(
                name: values.volumeName ?? PathTools.basename(mountPath),
                path: mountPath,
                fsType: fsType
            ))
        }
        return shares
    }

    @MainActor
    static func connect(_ target: String) -> OpResult {
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure("Enter a server or share address.") }
        let hasScheme = raw.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil
        let value = hasScheme ? raw : "smb://\(raw)"
        guard value.lowercased().hasPrefix("smb://") else {
            return .failure("Only SMB addresses are supported.")
        }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else {
            return .failure("Enter a server address.")
        }
        if NSWorkspace.shared.open(url) {
            return .success(path: value)
        }
        return .failure("Finder could not open this server.")
    }
}
