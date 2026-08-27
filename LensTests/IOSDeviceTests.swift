import XCTest
@testable import Lens

@MainActor
final class IOSDeviceTests: XCTestCase {

    // MARK: - Toolchain discovery

    func testToolchainPrefersDeveloperDirOverrideAndSkipsCommandLineTools() {
        let candidates = XcodeToolchain.candidateDirectories(
            environment: ["DEVELOPER_DIR": "/Volumes/Xcode-26/Xcode.app/Contents/Developer"],
            activeDeveloperDirectory: { "/Library/Developer/CommandLineTools" }
        )
        XCTAssertEqual(candidates.first?.path, "/Volumes/Xcode-26/Xcode.app/Contents/Developer")
        XCTAssertFalse(candidates.contains { $0.path.contains("CommandLineTools") })
        XCTAssertTrue(candidates.contains { $0.path == "/Applications/Xcode.app/Contents/Developer" })
    }

    func testToolchainUsesActiveDeveloperDirectoryWhenItIsARealXcode() {
        let candidates = XcodeToolchain.candidateDirectories(
            environment: [:],
            activeDeveloperDirectory: { "/Applications/Xcode-beta.app/Contents/Developer" }
        )
        XCTAssertEqual(candidates.first?.path, "/Applications/Xcode-beta.app/Contents/Developer")
    }

    func testToolchainDeduplicatesEquivalentCandidates() {
        let candidates = XcodeToolchain.candidateDirectories(
            environment: ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"],
            activeDeveloperDirectory: { "/Applications/Xcode.app/Contents/Developer" }
        )
        XCTAssertEqual(candidates.count, 1)
    }

    func testToolchainResolutionSkipsCandidatesWithoutSimctl() throws {
        // A bogus override must not win; resolution falls through to a real Xcode.
        let resolved = XcodeToolchain.resolve(
            environment: ["DEVELOPER_DIR": "/nonexistent/Developer"],
            activeDeveloperDirectory: { "/Library/Developer/CommandLineTools" }
        )
        if let resolved {
            XCTAssertNotEqual(resolved.developerDirectory.path, "/nonexistent/Developer")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved.simctlURL.path))
        } else {
            throw XCTSkip("No Xcode with simctl is installed on this machine.")
        }
    }

    func testToolchainResolutionFailsWhenNoCandidateProvidesSimctl() {
        XCTAssertNil(
            XcodeToolchain.resolve(
                environment: ["DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"],
                fileManager: NothingExecutableFileManager(),
                activeDeveloperDirectory: { "/Library/Developer/CommandLineTools" }
            )
        )
    }

    func testToolchainExposesSimctlAndDevicectlPaths() {
        let toolchain = XcodeToolchain(
            developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")
        )
        XCTAssertEqual(toolchain.simctlURL.path, "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl")
        XCTAssertEqual(toolchain.devicectlURL.path, "/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl")
    }

    // MARK: - simctl parsing

    private let simulatorJSON = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
          {
            "udid": "FA373F27-AA1D-4129-AE94-812C4C4F1632",
            "isAvailable": true,
            "state": "Booted",
            "name": "iPhone 17 Pro",
            "dataPath": "/Users/me/Library/Developer/CoreSimulator/Devices/FA373F27-AA1D-4129-AE94-812C4C4F1632/data"
          },
          {
            "udid": "A89E38D7-1524-4452-8459-559BA38E1ED5",
            "isAvailable": true,
            "state": "Shutdown",
            "name": "iPhone 17e"
          },
          {
            "udid": "00000000-0000-0000-0000-000000000000",
            "isAvailable": false,
            "state": "Shutdown",
            "name": "Broken Runtime Device"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
          {
            "udid": "11111111-1111-1111-1111-111111111111",
            "isAvailable": true,
            "state": "Booted",
            "name": "Apple Watch Series 10"
          }
        ]
      }
    }
    """

    func testParsingSimulatorsKeepsAvailableIOSDevicesOnly() throws {
        let simulators = IOSDeviceService.parseSimulators(Data(simulatorJSON.utf8))
        XCTAssertEqual(simulators.map(\.name), ["iPhone 17 Pro", "iPhone 17e"])
        let booted = try XCTUnwrap(simulators.first)
        XCTAssertTrue(booted.isBooted)
        XCTAssertEqual(booted.osVersion, "26.5")
        XCTAssertEqual(booted.runtimeName, "iOS 26.5")
        XCTAssertFalse(simulators[1].isBooted)
    }

    func testParsingSimulatorsIgnoresMalformedPayloads() {
        XCTAssertTrue(IOSDeviceService.parseSimulators(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(IOSDeviceService.parseSimulators(Data(#"{"devices":{}}"#.utf8)).isEmpty)
    }

    func testRuntimeIdentifierBecomesMarketingVersion() {
        XCTAssertEqual(
            IOSDeviceService.osVersion(fromRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-6"),
            "18.6"
        )
        XCTAssertEqual(
            IOSDeviceService.osVersion(fromRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"),
            ""
        )
    }

    // MARK: - devicectl parsing

    private let devicectlJSON = """
    {
      "result": {
        "devices": [
          {
            "identifier": "2EEC8047-6F5F-57AA-98F1-A4FF1A690FF5",
            "connectionProperties": { "tunnelState": "connected", "pairingState": "paired" },
            "deviceProperties": { "name": "Aman's iPhone", "osVersionNumber": "26.6" },
            "hardwareProperties": {
              "platform": "iOS",
              "reality": "physical",
              "marketingName": "iPhone 16 Pro Max",
              "udid": "00008140-00067C6E3C62401C"
            }
          },
          {
            "identifier": "53C89ADB-A23A-5744-AD89-0987B2F56A45",
            "connectionProperties": { "tunnelState": "unavailable" },
            "deviceProperties": { "name": "Elephant555", "osVersionNumber": "18.2" },
            "hardwareProperties": {
              "platform": "iOS",
              "reality": "physical",
              "marketingName": "iPhone 11",
              "udid": "00008030-000000000000001E"
            }
          },
          {
            "identifier": "99999999-0000-0000-0000-000000000000",
            "connectionProperties": { "tunnelState": "connected" },
            "deviceProperties": { "name": "Studio Display" },
            "hardwareProperties": { "platform": "macOS", "reality": "physical", "udid": "mac" }
          }
        ]
      }
    }
    """

    func testParsingPhysicalDevicesReportsConnectionStateAndSkipsOtherPlatforms() throws {
        let devices = IOSDeviceService.parsePhysicalDevices(Data(devicectlJSON.utf8))
        XCTAssertEqual(devices.count, 2)
        let connected = try XCTUnwrap(devices.first)
        XCTAssertEqual(connected.name, "Aman's iPhone")
        XCTAssertEqual(connected.osVersion, "26.6")
        XCTAssertEqual(connected.hardwareUDID, "00008140-00067C6E3C62401C")
        XCTAssertTrue(connected.isConnected)
        XCTAssertFalse(devices[1].isConnected)
    }

    // MARK: - Host proxy parsing and quoting

    func testParsingDefaultRouteInterface() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        XCTAssertEqual(HostProxyController.parseDefaultRouteInterface(output), "en0")
        XCTAssertNil(HostProxyController.parseDefaultRouteInterface("no route to host"))
    }

    func testParsingServiceNameForInterface() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (2) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (3) iPhone USB
        (Hardware Port: iPhone USB, Device: en8)
        """
        XCTAssertEqual(HostProxyController.parseServiceName(forInterface: "en0", in: output), "Wi-Fi")
        XCTAssertEqual(HostProxyController.parseServiceName(forInterface: "bridge0", in: output), "Thunderbolt Bridge")
        XCTAssertNil(HostProxyController.parseServiceName(forInterface: "en9", in: output))
    }

    func testParsingServiceNameHandlesDisabledServiceMarker() {
        let output = """
        (*4) Disabled Ethernet
        (Hardware Port: Ethernet, Device: en5)
        """
        XCTAssertEqual(
            HostProxyController.parseServiceName(forInterface: "en5", in: output),
            "Disabled Ethernet"
        )
    }

    func testParsingProxySetting() {
        let enabled = HostProxyController.parseProxySetting(
            """
            Enabled: Yes
            Server: 10.0.0.4
            Port: 8888
            Authenticated Proxy Enabled: 0
            """
        )
        XCTAssertEqual(enabled, HostProxySetting(isEnabled: true, host: "10.0.0.4", port: 8888))
        XCTAssertEqual(enabled.displayValue, "10.0.0.4:8888")

        let disabled = HostProxyController.parseProxySetting(
            """
            Enabled: No
            Server: 127.0.0.1
            Port: 9090
            """
        )
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.displayValue, "None")
    }

    func testServiceNameValidationRejectsShellMetacharacters() {
        XCTAssertTrue(HostProxyController.isSafeServiceName("Wi-Fi"))
        XCTAssertTrue(HostProxyController.isSafeServiceName("Ethernet (USB 10/100/1000 LAN)"))
        XCTAssertFalse(HostProxyController.isSafeServiceName("Wi-Fi; rm -rf /"))
        XCTAssertFalse(HostProxyController.isSafeServiceName("Wi-Fi`whoami`"))
        XCTAssertFalse(HostProxyController.isSafeServiceName("Wi-Fi$(id)"))
        XCTAssertFalse(HostProxyController.isSafeServiceName(""))
    }

    func testHostValidationRejectsUnexpectedCharacters() {
        XCTAssertTrue(HostProxyController.isSafeHost("127.0.0.1"))
        XCTAssertFalse(HostProxyController.isSafeHost("127.0.0.1 && curl evil.example"))
        XCTAssertFalse(HostProxyController.isSafeHost(""))
    }

    func testPrivilegedCommandQuotesArgumentsAndEscapesForAppleScript() {
        let command = HostProxyController.shellCommand(["-setwebproxy", "Ethernet (USB 10/100/1000 LAN)", "127.0.0.1", "8080"])
        XCTAssertEqual(
            command,
            "'/usr/sbin/networksetup' '-setwebproxy' 'Ethernet (USB 10/100/1000 LAN)' '127.0.0.1' '8080'"
        )

        let script = HostProxyController.appleScript(for: [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "8080"],
            ["-setwebproxystate", "Wi-Fi", "on"]
        ])
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        XCTAssertTrue(script.contains("&&"))
        // The inner single quotes must survive, and no unescaped double quote may appear
        // inside the AppleScript string literal.
        let body = script.dropFirst("do shell script \"".count).dropLast("\" with administrator privileges".count)
        XCTAssertFalse(body.contains("\""))
        XCTAssertTrue(body.contains("'-setwebproxystate' 'Wi-Fi' 'on'"))
    }

    // MARK: - Host proxy snapshot and restore

    func testApplyStoresOriginalSettingsOnceAndRestoreRecreatesThem() async throws {
        let defaults = try makeDefaults()
        let runner = ScriptedRunner()
        await runner.setResponses(networksetupResponses(webEnabled: false, host: "127.0.0.1", port: 9090))
        let authorizer = RecordingAuthorizer()
        let controller = HostProxyController(defaults: defaults, runner: runner, authorizer: authorizer)

        try await controller.apply(port: 8080)
        XCTAssertTrue(controller.isApplied)
        XCTAssertEqual(controller.appliedPort, 8080)
        let snapshot = try XCTUnwrap(controller.storedSnapshot())
        XCTAssertEqual(snapshot.serviceName, "Wi-Fi")
        XCTAssertFalse(snapshot.web.isEnabled)
        XCTAssertEqual(snapshot.web.port, 9090)

        // A second attach must not overwrite the snapshot with Lens's own settings.
        await runner.setResponses(networksetupResponses(webEnabled: true, host: "127.0.0.1", port: 8080))
        try await controller.apply(port: 8080)
        XCTAssertEqual(try XCTUnwrap(controller.storedSnapshot()).web.port, 9090)

        try await controller.restore()
        XCTAssertFalse(controller.isApplied)
        XCTAssertNil(controller.storedSnapshot())

        let scripts = await authorizer.scripts()
        XCTAssertEqual(scripts.count, 3)
        let restoreScript = try XCTUnwrap(scripts.last)
        XCTAssertTrue(restoreScript.contains("'-setwebproxy' 'Wi-Fi' '127.0.0.1' '9090'"))
        XCTAssertTrue(restoreScript.contains("'-setwebproxystate' 'Wi-Fi' 'off'"))
        XCTAssertTrue(restoreScript.contains("'-setsecurewebproxystate' 'Wi-Fi' 'off'"))
    }

    func testRestoreReenablesAProxyThatWasAlreadyOn() async throws {
        let defaults = try makeDefaults()
        let runner = ScriptedRunner()
        await runner.setResponses(networksetupResponses(webEnabled: true, host: "10.0.0.9", port: 3128))
        let authorizer = RecordingAuthorizer()
        let controller = HostProxyController(defaults: defaults, runner: runner, authorizer: authorizer)

        try await controller.apply(port: 8080)
        try await controller.restore()

        let restoreScripts = await authorizer.scripts()
        let restoreScript = try XCTUnwrap(restoreScripts.last)
        XCTAssertTrue(restoreScript.contains("'-setwebproxy' 'Wi-Fi' '10.0.0.9' '3128'"))
        XCTAssertTrue(restoreScript.contains("'-setwebproxystate' 'Wi-Fi' 'on'"))
    }

    func testApplyRejectsAnInvalidPortBeforeAskingForAuthorization() async throws {
        let defaults = try makeDefaults()
        let authorizer = RecordingAuthorizer()
        let controller = HostProxyController(defaults: defaults, runner: ScriptedRunner(), authorizer: authorizer)
        do {
            try await controller.apply(port: 0)
            XCTFail("Expected an invalid port to be refused")
        } catch {
            XCTAssertEqual(error as? HostProxyError, .invalidPort(0))
        }
        let attemptedScripts = await authorizer.scripts()
        XCTAssertTrue(attemptedScripts.isEmpty)
        XCTAssertNil(controller.storedSnapshot())
    }

    func testDeclinedAuthorizationLeavesNoSnapshotBehind() async throws {
        let defaults = try makeDefaults()
        let runner = ScriptedRunner()
        await runner.setResponses(networksetupResponses(webEnabled: false, host: "127.0.0.1", port: 9090))
        let controller = HostProxyController(
            defaults: defaults,
            runner: runner,
            authorizer: DecliningAuthorizer()
        )
        do {
            try await controller.apply(port: 8080)
            XCTFail("Expected the declined authorization to propagate")
        } catch {
            XCTAssertEqual(error as? HostProxyError, .authorizationDeclined)
        }
        XCTAssertFalse(controller.isApplied)
        XCTAssertFalse(
            controller.hasRecoverableSnapshot,
            "Nothing was changed, so the next launch must not ask to restore anything"
        )
    }

    func testDeclinedAuthorizationKeepsAnExistingSnapshot() async throws {
        let defaults = try makeDefaults()
        let runner = ScriptedRunner()
        await runner.setResponses(networksetupResponses(webEnabled: true, host: "10.0.0.9", port: 3128))
        let applied = HostProxyController(defaults: defaults, runner: runner, authorizer: RecordingAuthorizer())
        try await applied.apply(port: 8080)

        // A second attach that is declined must not discard the real snapshot.
        await runner.setResponses(networksetupResponses(webEnabled: true, host: "127.0.0.1", port: 8080))
        let declining = HostProxyController(defaults: defaults, runner: runner, authorizer: DecliningAuthorizer())
        try? await declining.apply(port: 8080)
        XCTAssertEqual(declining.storedSnapshot()?.web.port, 3128)
    }

    func testRestoreWithoutASnapshotIsANoOp() async throws {
        let defaults = try makeDefaults()
        let authorizer = RecordingAuthorizer()
        let controller = HostProxyController(defaults: defaults, runner: ScriptedRunner(), authorizer: authorizer)
        try await controller.restore()
        let noOpScripts = await authorizer.scripts()
        XCTAssertTrue(noOpScripts.isEmpty)
        XCTAssertFalse(controller.hasRecoverableSnapshot)
    }

    // MARK: - Simulator socket attribution

    func testParsingClientSocketsKeepsOnlyTheConnectingSide() {
        let output = """
        COMMAND    PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        mitmdump 89267 16aman    7u  IPv4 0xd085768a32e14c74      0t0  TCP 127.0.0.1:18081->127.0.0.1:64424 (ESTABLISHED)
        MobileSaf 89703 16aman   22u  IPv4 0xaa11bb22cc33dd44      0t0  TCP 127.0.0.1:64424->127.0.0.1:18081 (ESTABLISHED)
        curl      89851 16aman    5u  IPv4 0x1122334455667788      0t0  TCP 127.0.0.1:64425->127.0.0.1:18081 (ESTABLISHED)
        """
        let sockets = SimulatorTrafficAttribution.parseClientSockets(output, proxyPort: 18081)
        XCTAssertEqual(Set(sockets), [
            .init(pid: 89703, clientPort: 64424),
            .init(pid: 89851, clientPort: 64425)
        ])
        // The proxy's own accepted socket must never be treated as a client.
        XCTAssertFalse(sockets.contains { $0.pid == 89267 })
    }

    func testParsingClientSocketsIgnoresOtherPorts() {
        let output = """
        COMMAND    PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        Safari    1234 16aman   22u  IPv4 0xaa11bb22cc33dd44      0t0  TCP 127.0.0.1:5555->127.0.0.1:9999 (ESTABLISHED)
        """
        XCTAssertTrue(SimulatorTrafficAttribution.parseClientSockets(output, proxyPort: 18081).isEmpty)
    }

    private let processTable = """
        1     0 /sbin/launchd
    89173     1 launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/2ECC05F7-CD83-4AB7-9731-799525C06E31/data/var/run/launchd_bootstrap.plist
    89703 89173 /Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/Applications/MobileSafari.app/MobileSafari
    90100 89703 /Library/Developer/CoreSimulator/.../com.apple.WebKit.WebContent
    91000     1 /Applications/Safari.app/Contents/MacOS/Safari
    91500 90503 ugrep -G launchd_sim /some/path
    92000     1 launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/data/var/run/launchd_bootstrap.plist
    92100 92000 /Library/Developer/CoreSimulator/RuntimeRoot/Applications/MobileSafari.app/MobileSafari
    """

    func testParsingLaunchdSimulatorsMapsEachBootedDevice() {
        let map = SimulatorTrafficAttribution.parseLaunchdSimulators(processTable)
        XCTAssertEqual(map[89173], "2ECC05F7-CD83-4AB7-9731-799525C06E31")
        XCTAssertEqual(map[92000], "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(map.count, 2, "A grep command mentioning launchd_sim must not be treated as a simulator")
    }

    func testResolvingUDIDWalksTheParentChain() {
        let parents = SimulatorTrafficAttribution.parseParents(processTable)
        let launchdSimulators = SimulatorTrafficAttribution.parseLaunchdSimulators(processTable)

        // The simulator's own Safari, one hop from launchd_sim.
        XCTAssertEqual(
            SimulatorTrafficAttribution.resolveUDID(pid: 89703, parents: parents, udidByLaunchdSim: launchdSimulators),
            "2ECC05F7-CD83-4AB7-9731-799525C06E31"
        )
        // A WebContent child two hops away resolves to the same device.
        XCTAssertEqual(
            SimulatorTrafficAttribution.resolveUDID(pid: 90100, parents: parents, udidByLaunchdSim: launchdSimulators),
            "2ECC05F7-CD83-4AB7-9731-799525C06E31"
        )
        // A second booted simulator is kept distinct.
        XCTAssertEqual(
            SimulatorTrafficAttribution.resolveUDID(pid: 92100, parents: parents, udidByLaunchdSim: launchdSimulators),
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        // The Mac's own Safari belongs to no simulator.
        XCTAssertNil(
            SimulatorTrafficAttribution.resolveUDID(pid: 91000, parents: parents, udidByLaunchdSim: launchdSimulators)
        )
    }

    func testUDIDExtractionRequiresAFullIdentifier() {
        XCTAssertEqual(
            SimulatorTrafficAttribution.udid(inPath: "/x/CoreSimulator/Devices/2ECC05F7-CD83-4AB7-9731-799525C06E31/data"),
            "2ECC05F7-CD83-4AB7-9731-799525C06E31"
        )
        XCTAssertNil(SimulatorTrafficAttribution.udid(inPath: "/x/CoreSimulator/Devices/short/data"))
        XCTAssertNil(SimulatorTrafficAttribution.udid(inPath: "/Applications/Safari.app"))
    }

    func testSamplingResolvesSocketsAndPublishesTheMap() async throws {
        let lsof = """
        COMMAND    PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        MobileSaf 89703 16aman   22u  IPv4 0xaa11bb22cc33dd44      0t0  TCP 127.0.0.1:64424->127.0.0.1:18081 (ESTABLISHED)
        """
        let runner = ScriptedRunner()
        await runner.setResponses([
            CommandResult(output: lsof, errorOutput: "", status: 0),
            CommandResult(output: processTable, errorOutput: "", status: 0)
        ])
        let attribution = SimulatorTrafficAttribution(runner: runner)
        let observed = PublishedMaps()
        await attribution.setMapObserver { map in observed.append(map) }

        await attribution.sample(proxyPort: 18081)

        let udid = await attribution.udid(forClientPort: 64424)
        XCTAssertEqual(udid, "2ECC05F7-CD83-4AB7-9731-799525C06E31")
        XCTAssertEqual(observed.last()?[64424], "2ECC05F7-CD83-4AB7-9731-799525C06E31")
    }

    func testSamplingExpiresEntriesOlderThanTheRetentionWindow() async throws {
        let lsof = """
        COMMAND    PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        MobileSaf 89703 16aman   22u  IPv4 0xaa11bb22cc33dd44      0t0  TCP 127.0.0.1:64424->127.0.0.1:18081 (ESTABLISHED)
        """
        let runner = ScriptedRunner()
        await runner.setResponses([
            CommandResult(output: lsof, errorOutput: "", status: 0),
            CommandResult(output: processTable, errorOutput: "", status: 0),
            CommandResult(output: "", errorOutput: "", status: 0)
        ])
        let attribution = SimulatorTrafficAttribution(runner: runner)
        let start = Date(timeIntervalSince1970: 1_000_000)
        await attribution.sample(proxyPort: 18081, now: start)
        let freshEntry = await attribution.udid(forClientPort: 64424)
        XCTAssertNotNil(freshEntry)

        await attribution.sample(
            proxyPort: 18081,
            now: start.addingTimeInterval(SimulatorTrafficAttribution.retention + 1)
        )
        let expiredEntry = await attribution.udid(forClientPort: 64424)
        XCTAssertNil(expiredEntry)
    }

    // MARK: - Flow attribution

    func testLoopbackFlowIsAttributedToTheOwningSimulator() {
        let store = CaptureStore()
        let simulatorA = makeSimulatorTarget(udid: "SIM-A", name: "iPhone 17 Pro")
        let simulatorB = makeSimulatorTarget(udid: "SIM-B", name: "iPhone Air")
        store.simulatorUDIDResolver = { port in port == 64424 ? "SIM-B" : nil }

        let attributed = store.attributed(
            makeLoopbackFlow(clientPort: 64424),
            to: [simulatorA, simulatorB]
        )
        XCTAssertEqual(attributed.deviceID, "SIM-B")
        XCTAssertEqual(attributed.deviceName, "iPhone Air")
    }

    func testLoopbackFlowFromTheMacIsNotAttributedToASimulator() {
        let store = CaptureStore()
        let simulator = makeSimulatorTarget(udid: "SIM-A", name: "iPhone 17 Pro")
        store.simulatorUDIDResolver = { _ in nil }

        let attributed = store.attributed(makeLoopbackFlow(clientPort: 51000), to: [simulator])
        XCTAssertNil(attributed.deviceID, "Mac traffic must stay under Local machine")
        XCTAssertNil(attributed.deviceName)
    }

    func testSingleAndroidEmulatorStillClaimsLoopbackTraffic() {
        let store = CaptureStore()
        let emulator = DeviceTarget(
            serial: "emulator-5554", model: "sdk_gphone64_arm64", apiLevel: 35, kind: .emulator,
            rootState: .available, isAttached: true, previousProxy: nil, caInstalled: true
        )
        let attributed = store.attributed(makeLoopbackFlow(clientPort: nil), to: [emulator])
        XCTAssertEqual(attributed.deviceID, "emulator-5554")
    }

    func testIOSSimulatorDoesNotBreakTheAndroidEmulatorFallback() {
        let store = CaptureStore()
        let emulator = DeviceTarget(
            serial: "emulator-5554", model: "sdk_gphone64_arm64", apiLevel: 35, kind: .emulator,
            rootState: .available, isAttached: true, previousProxy: nil, caInstalled: true
        )
        let simulator = makeSimulatorTarget(udid: "SIM-A", name: "iPhone 17 Pro")
        store.simulatorUDIDResolver = { _ in nil }

        let attributed = store.attributed(makeLoopbackFlow(clientPort: 64424), to: [emulator, simulator])
        XCTAssertEqual(
            attributed.deviceID,
            "emulator-5554",
            "A booted simulator must not make the single-Android-emulator rule ambiguous"
        )
    }

    func testGuidedDeviceIsMatchedByItsBoundAddress() {
        let store = CaptureStore()
        var phone = makeSimulatorTarget(udid: "PHONE", name: "QA iPhone")
        phone.kind = .physical
        phone.attachmentMode = .guided
        phone.networkAddresses = ["192.168.1.42"]

        var flow = makeLoopbackFlow(clientPort: nil)
        flow.clientAddress = "192.168.1.42"
        XCTAssertEqual(store.attributed(flow, to: [phone]).deviceID, "PHONE")
    }

    // MARK: - Android-only tooling

    func testDeepInspectionIgnoresAttachedIOSDevices() {
        let inspector = AndroidInspectorManager()
        let simulator = makeSimulatorTarget(udid: "SIM-A", name: "iPhone 17 Pro")
        var phone = makeSimulatorTarget(udid: "PHONE", name: "QA iPhone")
        phone.kind = .physical
        phone.attachmentMode = .guided

        inspector.updateDevices([simulator, phone])

        // No ADB polling may start for an iOS target, so it has no inspection state.
        XCTAssertEqual(inspector.state(for: simulator), .idle)
        XCTAssertEqual(inspector.state(for: phone), .idle)
    }

    // MARK: - Bridge framing

    func testFramerSplitsLinesAcrossChunkBoundaries() {
        var framer = JSONLineFramer()
        XCTAssertTrue(framer.append(Data(#"{"a":1}"#.utf8)).isEmpty)
        let firstLines = framer.append(Data("\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(firstLines.map { String(decoding: $0, as: UTF8.self) }, [#"{"a":1}"#, #"{"b":2}"#])
        let secondLines = framer.append(Data(":3}\n".utf8))
        XCTAssertEqual(secondLines.map { String(decoding: $0, as: UTF8.self) }, [#"{"c":3}"#])
    }

    func testFramerSkipsEmptyLinesAndSurvivesManyRounds() {
        var framer = JSONLineFramer()
        XCTAssertTrue(framer.append(Data("\n\n".utf8)).isEmpty)
        // Repeated appends exercise the buffer's index space after each removal.
        for index in 0..<200 {
            let payload = #"{"index":\#(index)}"#
            let lines = framer.append(Data((payload + "\n").utf8))
            XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [payload])
        }
    }

    func testFramerHandlesALineLargerThanASingleChunk() {
        var framer = JSONLineFramer()
        let body = String(repeating: "x", count: 200_000)
        let payload = #"{"body":"\#(body)"}"#
        var emitted: [Data] = []
        for chunk in Array(Data((payload + "\n").utf8)).chunked(into: 64 * 1024) {
            emitted += framer.append(Data(chunk))
        }
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first.map { String(decoding: $0, as: UTF8.self) }, payload)
    }

    // MARK: - Device model

    func testPlatformSpecificPresentation() {
        let android = DeviceTarget(
            serial: "emulator-5554", model: "sdk_gphone64_arm64", apiLevel: 35, kind: .emulator,
            rootState: .available, isAttached: false, previousProxy: nil, caInstalled: false
        )
        XCTAssertEqual(android.platform, .android, "Existing devices must keep decoding as Android")
        XCTAssertEqual(android.platformVersionText, "Android API 35")
        XCTAssertTrue(android.supportsAndroidTooling)
        XCTAssertFalse(android.isSimulator)

        let simulator = makeSimulatorTarget(udid: "SIM-A", name: "iPhone 17 Pro")
        XCTAssertEqual(simulator.platformVersionText, "iOS 26.5")
        XCTAssertFalse(simulator.supportsAndroidTooling)
        XCTAssertTrue(simulator.isSimulator)
        XCTAssertNotEqual(simulator.symbolName, android.symbolName)
    }

    func testFlowRecordDecodesWithoutAClientPort() throws {
        let json = """
        {
          "id": "flow-1", "clientAddress": "127.0.0.1", "method": "GET", "scheme": "https",
          "host": "example.com", "port": 443, "path": "/", "url": "https://example.com/",
          "requestHeaders": [], "responseHeaders": [], "startedAt": 0, "size": 0,
          "websocketMessages": []
        }
        """
        let flow = try JSONDecoder().decode(FlowRecord.self, from: Data(json.utf8))
        XCTAssertNil(flow.clientPort)
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "LensTests.IOSDevice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func networksetupResponses(webEnabled: Bool, host: String, port: Int) -> [CommandResult] {
        let route = "   route to: default\n  interface: en0\n"
        let order = "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n"
        let proxy = "Enabled: \(webEnabled ? "Yes" : "No")\nServer: \(host)\nPort: \(port)\n"
        return [
            CommandResult(output: route, errorOutput: "", status: 0),
            CommandResult(output: order, errorOutput: "", status: 0),
            CommandResult(output: proxy, errorOutput: "", status: 0),
            CommandResult(output: proxy, errorOutput: "", status: 0)
        ]
    }

    private func makeSimulatorTarget(udid: String, name: String) -> DeviceTarget {
        DeviceTarget(
            serial: udid, model: name, apiLevel: 0, kind: .emulator, rootState: .available,
            isAttached: true, previousProxy: nil, caInstalled: true, networkAddresses: [],
            hardwareID: udid, platform: .ios, osVersion: "26.5", attachmentMode: .automatic
        )
    }

    private func makeLoopbackFlow(clientPort: Int?) -> FlowRecord {
        FlowRecord(
            id: "flow-\(clientPort ?? 0)", clientAddress: "127.0.0.1", clientPort: clientPort,
            method: "GET", scheme: "https", host: "example.com", port: 443, path: "/",
            url: "https://example.com/", requestHeaders: [], requestBody: nil,
            responseStatus: 200, responseReason: "OK", responseHeaders: [], responseBody: nil,
            startedAt: 0, endedAt: 1, duration: 1, size: 0,
            mappedRuleID: nil, mappedRuleName: nil, error: nil, websocketMessages: []
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - Test doubles

/// Reports that no file is executable, so toolchain resolution finds nothing.
private final class NothingExecutableFileManager: FileManager {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}

private actor ScriptedRunner: CommandRunning {
    private var responses: [CommandResult] = []
    private var calls: [[String]] = []

    func setResponses(_ values: [CommandResult]) {
        responses = values
    }

    func recordedCalls() -> [[String]] {
        calls
    }

    func run(
        _ executable: URL,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval?
    ) async throws -> CommandResult {
        calls.append([executable.path] + arguments)
        guard !responses.isEmpty else {
            return CommandResult(output: "", errorOutput: "Missing scripted response", status: 1)
        }
        return responses.removeFirst()
    }
}

/// Stands in for the user clicking Cancel on the macOS authorization dialog.
private struct DecliningAuthorizer: PrivilegedCommandAuthorizing {
    func run(script: String, reason: String) async throws {
        throw HostProxyError.authorizationDeclined
    }
}

private actor RecordingAuthorizer: PrivilegedCommandAuthorizing {
    private var recorded: [String] = []

    func run(script: String, reason: String) async throws {
        recorded.append(script)
    }

    func scripts() -> [String] {
        recorded
    }
}

/// Collects the maps published by the attribution actor.
private final class PublishedMaps: @unchecked Sendable {
    private let lock = NSLock()
    private var maps: [[Int: String]] = []

    func append(_ map: [Int: String]) {
        lock.withLock { maps.append(map) }
    }

    func last() -> [Int: String]? {
        lock.withLock { maps.last }
    }
}
