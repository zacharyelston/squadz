import Darwin
import Foundation
import TheaterKit

@main
struct TheaterMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("""
            Squadz Theater — observe squads on this network, in browser windows.
            Usage: swift run --package-path theater squadz-theater [options]
              --port 8765             Web port (default: 8765)
              --bind 127.0.0.1         Loopback by default; explicit private IPv4 enables LAN/passcode
              --invite-stdin          Read an invite link from stdin (never put it in shell history)
              --no-http               T1: print state updates as JSON without serving pages
              --name Theater          Observer name shown on the leader's device
              --endpoint IP:PORT      Fixed local/private IPv4 endpoint instead of Bonjour
              --tiles DIRECTORY       Offline XYZ PNG tiles as z/x/y.png; no external tile requests
              --tile-attribution TEXT Map credit for your tile source
              --tile-max-zoom 18      Deepest tile level (0–22)
              --data-dir DIRECTORY   Nonsecret squad index; observer credentials stay in Keychain
              --demo                  Two labeled sample squads using ephemeral local links
              --demo-map              With --demo: online OpenStreetMap tiles for samples only
            Pair on http://127.0.0.1:8765/ using an invite from the leader. Open each view in its own window.
            Video stays leader-only. The Theater never sends orders, notes, positions or zone edits.
            """)
            return
        }
        do {
            let options = try TheaterOptions.parse(args)
            let controller = try TheaterController(options: options, persist: !options.fixture)
            if let endpoint = options.endpoint { controller.fixedEndpoint = { _ in endpoint } }
            var server: TheaterHTTPServer?
            if !options.noHTTP {
                let http = TheaterHTTPServer(controller: controller)
                http.onReady = { port in
                    print("Theater: http://\(options.bind == "::1" ? "[::1]" : "127.0.0.1"):\(port)/")
                    if !options.isLoopback { print("LAN views: http://\(options.bind):\(port)/\nView passcode: \(http.access.passcode ?? "")\nPair new squads only on the host Mac's loopback page.") }
                    fflush(stdout)
                }
                http.onError = { error in fputs("\(error)\n", stderr); exit(1) }
                try http.start(); server = http
            } else {
                controller.onChange = { if let data = try? controller.json(), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) } }
            }
            controller.start(discover: !options.fixture)
            let demo = options.fixture ? try TheaterDemo(controller: controller) : nil
            if options.demoMap { print("DEMO MAP: browser loads OpenStreetMap tiles online; real-squad pairing is disabled."); fflush(stdout) }
            if options.fixture { print("DEMO: ephemeral sample squads and positions, not real members."); fflush(stdout) }
            if options.inviteStdin {
                fputs("Paste the squad invite link, then press Return:\n", stderr)
                guard let invite = readLine(), !invite.isEmpty else { throw TheaterError.message("No invite on stdin.") }
                try controller.join(invite, name: options.observerName)
            }
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let stop = { MainActor.assumeIsolated { demo?.stop(); controller.stop(); server?.stop(); exit(0) } }
            interrupt.setEventHandler(handler: stop); terminate.setEventHandler(handler: stop)
            interrupt.resume(); terminate.resume()
            withExtendedLifetime((controller, server, demo, interrupt, terminate)) { RunLoop.main.run() }
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
