import Foundation
import SystemIntegrationAPI

/// Maps raw notification values so the mapping remains available to tests on
/// platforms where AVFAudio is not present.
enum AppleAudioSessionEventMapper {
    static let interruptionEndedRawValue: UInt = 0
    static let interruptionBeganRawValue: UInt = 1
    static let interruptionShouldResumeMask: UInt = 1

    static let routeNewDeviceAvailableRawValue: UInt = 1
    static let routeOldDeviceUnavailableRawValue: UInt = 2
    static let routeCategoryChangeRawValue: UInt = 3
    static let routeOverrideRawValue: UInt = 4
    static let routeWakeFromSleepRawValue: UInt = 6
    static let routeNoSuitableRouteRawValue: UInt = 7
    static let routeConfigurationChangeRawValue: UInt = 8

    static func interruption(
        typeRawValue: UInt,
        optionsRawValue: UInt
    ) -> AudioSessionEvent? {
        switch typeRawValue {
        case interruptionBeganRawValue:
            return .interruption(.began)
        case interruptionEndedRawValue:
            let shouldResume = (optionsRawValue & interruptionShouldResumeMask) != 0
            return .interruption(.ended(shouldResume: shouldResume))
        default:
            return nil
        }
    }

    static func routeChange(
        reasonRawValue: UInt,
        outputAvailable: Bool?,
        inputAvailable: Bool?
    ) -> AudioSessionEvent {
        .routeChanged(
            AudioRouteChange(
                reason: routeReason(rawValue: reasonRawValue),
                isOutputAvailable: outputAvailable,
                isInputAvailable: inputAvailable
            )
        )
    }

    static func routeReason(rawValue: UInt) -> AudioRouteChangeReason {
        switch rawValue {
        case routeNewDeviceAvailableRawValue:
            .newDeviceAvailable
        case routeOldDeviceUnavailableRawValue:
            .oldDeviceUnavailable
        case routeCategoryChangeRawValue:
            .categoryChange
        case routeOverrideRawValue:
            .override
        case routeWakeFromSleepRawValue:
            .wakeFromSleep
        case routeNoSuitableRouteRawValue:
            .noSuitableRouteForCategory
        case routeConfigurationChangeRawValue:
            .routeConfigurationChange
        default:
            .unknown
        }
    }

    static func unsignedValue(_ value: Any?) -> UInt? {
        switch value {
        case let value as UInt:
            value
        case let value as UInt32:
            UInt(value)
        case let value as UInt16:
            UInt(value)
        case let value as UInt8:
            UInt(value)
        case let value as Int where value >= 0:
            UInt(value)
        case let value as NSNumber where value.int64Value >= 0:
            UInt(value.int64Value)
        default:
            nil
        }
    }
}
