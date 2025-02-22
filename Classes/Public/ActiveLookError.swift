/*
 
Copyright 2021 Microoled
Licensed under the Apache License, Version 2.0 (the “License”);
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an “AS IS” BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
 
*/

import CoreBluetooth

/// ActiveLook specific errors
public enum ActiveLookError: Error {
    case unknownError
    case connectionTimeoutError
    case bluetoothPoweredOffError
    case bluetoothUnsupportedError
    case bluetoothUnauthorizedError
    case initializationError
}

extension ActiveLookError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownError:
            return "Unknown error"
        case .connectionTimeoutError:
            return "Connection timeout error"
        case .bluetoothUnsupportedError:
            return "Bluetooth is not supported on this device"
        case .bluetoothUnauthorizedError:
            return "Bluetooth is not authorized on this device"
        case .bluetoothPoweredOffError:
            return "Bluetooth is powered off"
        case .initializationError:
            return "Error while initializing glasses"
        }
    }
    
    internal static func bluetoothErrorFromState(state: CBManagerState) -> Error {
        switch state {
        case .poweredOff:
            return ActiveLookError.bluetoothPoweredOffError
        case .unsupported:
            return ActiveLookError.bluetoothUnsupportedError
        case .unauthorized:
            return ActiveLookError.bluetoothUnauthorizedError
        default:
            return ActiveLookError.unknownError
        }
    }
}
