import Foundation

/// Runs one read-only inventory of a target: a single ssh connection that
/// inspects the container (if any) and runs `InventoryProbe` inside it.
public enum TargetProbe {
    public static func run(
        host: HostConfig,
        target: TargetConfig,
        options: SSHOptions = SSHOptions(),
        timeoutSeconds: Int = 20
    ) async -> Result<InventorySnapshot, RemoteFailure> {
        let tmux: TmuxInvocation
        do {
            tmux = try target.executionContext().tmux
        } catch {
            return .failure(RemoteFailure(.remoteCommandFailed, detail: "\(error)"))
        }
        let nonce = makeNonce()
        let output = await RemoteScript.run(
            InventoryProbe.script(tmux: tmux, nonce: nonce),
            host: host, target: target, options: options, timeoutSeconds: timeoutSeconds
        )
        return output.flatMap { text in
            do {
                return try .success(InventoryProbe.parse(text, nonce: nonce))
            } catch let failure as RemoteFailure {
                return .failure(failure)
            } catch {
                return .failure(RemoteFailure(.protocolDesync, detail: "\(error)"))
            }
        }
    }

    static func makeNonce() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 16).map { _ in alphabet.randomElement()! })
    }
}
