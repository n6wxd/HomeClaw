import ArgumentParser
import Foundation

struct HomeKitCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "homekit-cli",
        abstract: "Control HomeKit accessories via HomeKit Bridge",
        subcommands: [
            List.self,
            Get.self,
            Set.self,
            Scenes.self,
            Trigger.self,
            Search.self,
            Status.self,
            Config.self,
            DeviceMapCmd.self,
        ],
        defaultSubcommand: Status.self
    )
}
