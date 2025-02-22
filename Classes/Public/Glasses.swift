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

import Foundation
import CoreBluetooth

/// A representation of connected ActiveLook® glasses.
///
/// Commands can be sent directly using the corresponding method.
///
/// If a response from the glasses is expected, it can be handled by providing a closure to the callback argument.
///
/// It is possible to subscribe to three different types of notifications by providing a callback closure using the corresponding method.
///
/// The glasses will send updates about the current battery level once every 30 seconds.
///
/// They will notify about the state of the flow control whenever it changes.
///
/// Finally, the registered callback will be triggered when a gesture is detected by the gesture detection sensor.
///
/// To disconnect from the glasses, simply call the `disconnect()` method.
///
public class Glasses {
    
    
    // MARK: - Public properties
    
    /// The name of the glasses, as advertised over Bluetooth.
    public var name: String
    
    /// The identifier of the glasses, as advertised over Bluetooth. It is not guaranteed to be unique over a certain period and across sessions.
    public var identifier: UUID
    
    /// The manufacturer id as set on the device as a hex string.
    public var manufacturerId: String
    

    // MARK: - Internal properties
    
    internal var centralManager: CBCentralManager
    internal var peripheral: CBPeripheral
    internal var peripheralDelegate: PeripheralDelegate

    internal var disconnectionCallback: (() -> Void)?
    
    
    // MARK: - Private properties

    private var batteryLevelUpdateCallback: ((Int) -> Void)?
    private var flowControlUpdateCallback: ((FlowControlState) -> Void)?
    private var sensorInterfaceTriggeredCallback: (() -> Void)?
    
    // Query ids are handled internally by the SDK. The queryId variable is used to keep track of
    // the last queryId sent to the glasses and increment the value for each new command
    private var queryId: UInt8
    
    // An array used to track queries (commands expecting a response) and match them to a corresponding callback returning the response data as a byte array ([UInt8]).
    private var pendingQueries: [UInt8: (CommandResponseData) -> Void]
    
    // A buffer used to squash response chunks into a single CommandResponseData
    private var responseBuffer: [UInt8]?
    
    // The expected size of the response buffer
    private var expectedResponseBufferLength: Int
    
    private var deviceInformationService: CBService? {
        return peripheral.getService(withUUID: CBUUID.DeviceInformationService)
    }
    
    private var batteryService: CBService? {
        return peripheral.getService(withUUID: CBUUID.BatteryService)
    }
    
    private var activeLookService: CBService? {
        return peripheral.getService(withUUID: CBUUID.ActiveLookCommandsInterfaceService)
    }
    
    private var batteryLevelCharacteristic: CBCharacteristic? {
        return batteryService?.getCharacteristic(forUUID: CBUUID.BatteryLevelCharacteristic)
    }
    
    private var rxCharacteristic: CBCharacteristic? {
        return activeLookService?.getCharacteristic(forUUID: CBUUID.ActiveLookRxCharacteristic)
    }
    
    private var txCharacteristic: CBCharacteristic? {
        return activeLookService?.getCharacteristic(forUUID: CBUUID.ActiveLookTxCharacteristic)
    }
    
    private var flowControlCharacteristic: CBCharacteristic? {
        return activeLookService?.getCharacteristic(forUUID: CBUUID.ActiveLookFlowControlCharacteristic)
    }
    
    private var sensorInterfaceCharacteristic: CBCharacteristic? {
        return activeLookService?.getCharacteristic(forUUID: CBUUID.ActiveLookSensorInterfaceCharacteristic)
    }
    
    // MARK: - Initializers
    
    internal init(name: String, identifier: UUID, manufacturerId: String, peripheral: CBPeripheral, centralManager: CBCentralManager) {
        self.name = name
        self.identifier = identifier
        self.manufacturerId = manufacturerId
        self.peripheral = peripheral
        self.centralManager = centralManager
        
        self.queryId = 0x00
        self.pendingQueries = [:]
        self.responseBuffer = nil
        self.expectedResponseBufferLength = 0
        self.peripheralDelegate = PeripheralDelegate()
        self.peripheralDelegate.parent = self
    }

    internal convenience init(discoveredGlasses: DiscoveredGlasses) {
        self.init(
            name: discoveredGlasses.name,
            identifier: discoveredGlasses.identifier,
            manufacturerId: discoveredGlasses.manufacturerId,
            peripheral: discoveredGlasses.peripheral,
            centralManager: discoveredGlasses.centralManager
        )
        self.disconnectionCallback = discoveredGlasses.disconnectionCallback
    }
    

    // MARK: - Private methods
    
    private func getNextQueryId() -> UInt8 {
        queryId = (queryId + 1) % 255
        return queryId
    }

    private func sendCommand(id commandId: CommandID, withData data: [UInt8]? = [], callback: ((CommandResponseData) -> Void)? = nil) {
        let header: UInt8 = 0xFF, footer: UInt8 = 0xAA
        let queryId = getNextQueryId()
        
        let defaultLength: Int = 5 // Header + CommandId + CommandFormat + Command length (one byte) + Footer
        let queryLength: Int = 1 // Query ID is used internally and always encoded on 1 byte
        let dataLength: Int = data?.count ?? 0
        var totalLength: Int = defaultLength + queryLength + dataLength
        
        if totalLength > 255 {
            totalLength += 1 // We must add one byte to encode length on 2 bytes
        }
    
        let commandFormat: UInt8 = UInt8((totalLength > 255 ? 0x10 : 0x00) | queryLength)

        var bytes = [header, commandId.rawValue, commandFormat]
        
        if totalLength > 255 {
            bytes.append(contentsOf: Int16(totalLength).asUInt8Array) // Encode on 2 bytes
        } else {
            bytes.append(UInt8(totalLength))
        }
        
        bytes.append(queryId)
        if (data != nil) { bytes.append(contentsOf: data!) }
        bytes.append(footer)
        
        if callback != nil {
            pendingQueries[queryId] = callback
        }

        sendBytes(bytes: bytes)
    }
    
    private func sendCommand(id: CommandID, withValue value: Bool) {
        sendCommand(id: id, withData: value ? [0x01] : [0x00])
    }
    
    private func sendCommand(id: CommandID, withValue value: UInt8) {
        sendCommand(id: id, withData: [value])
    }

    private func sendBytes(bytes: [UInt8]) {
        print("sending bytes to peripheral: \(bytes)")
        let value = Data(_: bytes)
        
        peripheral.writeValue(value, for: rxCharacteristic!, type: .withResponse)
    }
    
    private func handleTxNotification(withData data: Data) {
        let bytes = [UInt8](data)
        print("received notification for tx characteristic with data: \(bytes)")
        
        if responseBuffer != nil { // If we're currently filling up the response buffer, handle differently
            handleChunkedResponse(withData: bytes)
            return
        }
        
        guard data.count >= 6 else { return } // Header + CommandID + CommandFormat + QueryID + Length + Footer // TODO Raise error

        let handledCommandIDs: [UInt8] = [
            CommandID.battery, CommandID.vers, CommandID.settings, CommandID.getSensorParameters, CommandID.imgList,
            CommandID.pixelCount, CommandID.getChargingCounter, CommandID.getChargingTime, CommandID.getMaxPixelValue,
            CommandID.rConfigID
        ].map({$0.rawValue})
        
        let commandId = bytes[1]
        let commandFormat = bytes[2]

        guard handledCommandIDs.contains(commandId) else { return } // TODO Log
        guard commandFormat == 0x01 || commandFormat == 0x11 else { return } // TODO Log
        
        let totalLength: Int = commandFormat == 0x01 ? Int(bytes[3]) : Int.fromUInt16ByteArray(bytes: [bytes[3], bytes[4]])
        
        if totalLength == data.count {
            handleCompleteResponse(withData: bytes)
        } else {
            expectedResponseBufferLength = totalLength
            handleChunkedResponse(withData: bytes)
        }
    }
    
    private func handleCompleteResponse(withData data: [UInt8]) {
        guard data.count >= 6 else { return } // Header + CommandID + CommandFormat + QueryID + Length + Footer // TODO Raise error

        let header = data[0]
        let footer = data[data.count - 1]
        guard header == 0xFF else { return } // TODO Raise error
        guard footer == 0xAA else { return } // TODO Raise error

        let commandFormat = data[2]
        let queryId = commandFormat == 0x01 ? data[4] : data[5]
        
        var commandData: [UInt8] = []
        let commandDataStartIndex = commandFormat == 0x01 ? 5 : 6
        
        if commandDataStartIndex <= (data.count - 1 - 1) { // Else there is no data
            commandData = Array(data[commandDataStartIndex...(data.count - 1 - 1)])
        }

        if let callback = pendingQueries[queryId] {
            callback(commandData)
            pendingQueries[queryId] = nil
        }
    }
    
    // Handle chuncked responses (Glasses will answer as 20 bytes chunks if response is longer)
    //
    // We cannot reliably check for the presence of headers and footers as each chunk may contain any data.
    // Instead, we're adding every chunk of data we receive to a buffer until the expected response length is reached.
    //
    // If some chunks are dropped / never received, we will, for now, incorrectly push data to the response buffer until
    // the expected response length is reached.
    private func handleChunkedResponse(withData data: [UInt8]) {
        if responseBuffer == nil { responseBuffer = [] } // Create response buffer if first chunk

        responseBuffer!.append(contentsOf: data)
                
        guard responseBuffer!.count <= expectedResponseBufferLength else {
            print("buffer overflow error: \(data)") // TODO Raise error
            return
        }

        if responseBuffer!.count == expectedResponseBufferLength {

            guard responseBuffer![0] == 0xFF, responseBuffer![responseBuffer!.count - 1] == 0xAA else {
                print("buffer format error") // TODO Raise error
                return
            }

            let completeData = responseBuffer!
            handleCompleteResponse(withData: completeData)
            responseBuffer = nil
            expectedResponseBufferLength = 0
        }
    }


    // MARK: - Public methods

    /// Disconnect from the glasses.
    public func disconnect() {
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    /// Set the callback to be called when the connection to the glasses is lost.
    /// - Parameter disconnectionCallback: A callback called asynchronously when the device is disconnected.
    public func onDisconnect(_ disconnectionCallback: (() -> Void)?) {
        self.disconnectionCallback = disconnectionCallback
    }
    
    /// Get information relative to the device as published over Bluetooth.
    /// - Returns: The current information about the device, including its manufacturer name, model number, serial number, hardware version, software version and firmware version.
    public func getDeviceInformation() -> DeviceInformation {
        guard deviceInformationService != nil else {
            return DeviceInformation()
        }
        
        return DeviceInformation(
            deviceInformationService?.getCharacteristic(forUUID: CBUUID.ManufacturerNameCharacteristic)?.valueAsUTF8,
            deviceInformationService?.getCharacteristic(forUUID: CBUUID.ModelNumberCharacteristic)?.valueAsUTF8,
            deviceInformationService?.getCharacteristic(forUUID: CBUUID.SerialNumberCharateristic)?.valueAsUTF8,
            deviceInformationService?.getCharacteristic(forUUID: CBUUID.HardwareVersionCharateristic)?.valueAsUTF8,
            deviceInformationService?.getCharacteristic(forUUID: CBUUID.FirmwareVersionCharateristic)?.valueAsUTF8,
            deviceInformationService?.getCharacteristic(forUUID: CBUUID.SoftwareVersionCharateristic)?.valueAsUTF8
        )
    }
    
    
    // MARK: - Utility commands
    /// Check if firmware is at least
    /// - Parameter version: the version to compare to
    public func isFirmwareAtLeast(version: String) -> Bool {
        let gVersion = self.getDeviceInformation().firmwareVersion
        guard gVersion != nil else { return false }
        if (gVersion ?? "" >= "v\(version).0b") {
            return true
        } else {
            return false
        }
    }

    /// Compare the firmware against a certain version
    /// - Parameter version: the version to compare to
    public func compareFirmwareAtLeast(version: String) -> ComparisonResult {
        let gVersion = self.getDeviceInformation().firmwareVersion
        return (gVersion ?? "").compare("v\(version).0b")
    }
    
    /// load a configuration file
    public func loadConfiguration(cfg: [String]) -> Void {
        for line in cfg {
            sendBytes(bytes: line.hexaBytes)
        }
    }

    // MARK: - General commands
    
    /// Power the device on or off.
    /// - Parameter on: on if true, off otherwise
    public func power(on: Bool) {
        sendCommand(id: .power, withValue: on)
    }
    
    /// Clear the whole screen.
    public func clear() {
        sendCommand(id: .clear)
    }
    
    /// /// Set the whole display to the corresponding grey level
    /// - Parameter level: The grey level between 0 and 15
    public func grey(level: UInt8) {
        sendCommand(id: .grey, withValue: level)
    }
    
    /// Display the demonstration pattern
    public func demo() {
        sendCommand(id: .demo)
    }
    
    /// Display the test pattern from demo command fw 4.0
    /// - Parameter pattern: The demo pattern. 0: Fill screen. 1: Rectangle with a cross in it. 2: Image
    public func demo(pattern: DemoPattern) {
        sendCommand(id: .demo, withValue: pattern.rawValue)
    }
    
    /// Display the test pattern
    /// - Parameter pattern: The demo pattern. 0: Fill screen. 1: Rectangle with a cross in it
    public func test(pattern: DemoPattern) {
        sendCommand(id: .test, withValue: pattern.rawValue)
    }
    
    /// Get the battery level
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func battery(_ callback: @escaping (Int) -> Void) {
        sendCommand(id: .battery, withData: nil) { (commandResponseData) in
            guard commandResponseData.count >= 1 else { return }
            callback(Int(commandResponseData[0]))
        }
    }
    
    /// Get the glasses version parameters such as device ID and firmware version
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func vers(_ callback: @escaping (GlassesVersion) -> Void) {
        sendCommand(id: .vers, withData: nil) { (commandResponseData) in
            callback(GlassesVersion.fromCommandResponseData(commandResponseData))
        }
    }
    
    /// Return BLE data to USB
    /// - Parameter enabled: Enabled if true, disabled otherwise.
    public func debug(_ enabled: Bool) {
        sendCommand(id: .debug, withValue: enabled)
    }

    /// Set the state of the green LED
    /// - Parameter state: The led state between off, on, toggle and blinking
    public func led(state: LedState) {
        sendCommand(id: .led, withValue: state.rawValue)
    }
    
    /// Shift all subsequent displayed object of (x,y) pixels
    /// - Parameters:
    ///   - x: The horizontal shift, between -128 and 127
    ///   - y: The vertical shift, between -128 and 127
    public func shift(x: Int16, y: Int16) {
        var data: [UInt8] = []
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)

        sendCommand(id: .shift, withData: data)
    }
    
    /// Get the glasses settings such as screen shift, luma and sensor information
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func settings(_ callback: @escaping (GlassesSettings) -> Void) {
        sendCommand(id: .settings, withData: nil) { (commandResponseData) in
            callback(GlassesSettings.fromCommandResponseData(commandResponseData))
        }
    }
    
    /// Set a customized BLE advertising name.
    /// The maximum length is 15. An empty name will reset factory name
    /// - Parameter name: The name to be set
    public func setName(_ name: String) {
        sendCommand(id: .setName, withData: Array(name.utf8))
    }
    
    
    // MARK: - Luma commands
    
    /// Set the display luminance to the corresponding level
    /// - Parameter level: The luma level between 0 and 15
    public func luma(level: UInt8) {
        sendCommand(id: .luma, withValue: level)
    }
    
    /// Reduce luminance to given percentage
    /// - Parameter level: The applied dim level between 0 and 100
    public func dim(level: UInt8) {
        sendCommand(id: .dim, withValue: level)
    }
    
    
    // MARK: - Optical sensor commands
    
    /// Turn on/off the auto brightness adjustment and gesture detection
    /// - Parameter enabled: enabled if true, disabled otherwise
    public func sensor(enabled: Bool) {
        sendCommand(id: .sensor, withValue: enabled)
    }
    
    /// Turn on/off the gesture detection
    /// - Parameter enabled: enabled if true, disabled otherwise
    public func gesture(enabled: Bool) {
        sendCommand(id: .gesture, withValue: enabled)
    }
    
    /// Turn on/off the auto brightness adjustment
    /// - Parameter enabled: enabled if true, disabled otherwise
    public func als(enabled: Bool) {
        sendCommand(id: .als, withValue: enabled)
    }
    
    
    
    
    /// /// Set optical sensor parameters. Only the parameters corresponding to the specified mode will be set.
    /// - Parameters:
    ///   - sensorMode: The mode to configure
    ///   - sensorParameters: The sensor parameters to set
    public func setSensorParameters(mode sensorMode: SensorMode, sensorParameters: SensorParameters) {
        var data: [UInt8] = [sensorMode.rawValue]
        
        switch sensorMode {
        case .ALSArray:
            for alsArrayItem in sensorParameters.alsArray {
                data.append(contentsOf: alsArrayItem.asUInt8Array)
            }
        case .ALSPeriod:
            data.append(contentsOf: sensorParameters.alsPeriod.asUInt8Array)
        case.rangingPeriod:
            data.append(contentsOf: sensorParameters.rangingPeriod.asUInt8Array)
        }

        sendCommand(id: .setSensorParameters, withData: data)
    }
    
    /// Get sensor parameters (ALS Array, ALS Period and ranging Period).
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func getSensorParameters(_ callback: @escaping (SensorParameters) -> Void) {
        sendCommand(id: .getSensorParameters, withData: nil) { (commandResponseData) in
            let sensorParameters = SensorParameters.fromCommandResponseData(commandResponseData)
            callback(sensorParameters)
        }
    }
    
    
    // MARK: - Graphics commands
    
    /// Sets the grey level used to draw the next graphical element
    /// - Parameter level: The grey level to be used between 0 and 15
    public func color(level: UInt8) {
        sendCommand(id: .color, withValue: level)
    }
    
    /// Set a pixel on at the corresponding coordinates
    /// - Parameters:
    ///   - x: The x coordinate
    ///   - y: The y coordinate
    public func point(x: Int16, y: Int16) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)

        sendCommand(id: .point, withData: data)
    }
    
    /// Draw a line at the corresponding coordinates
    /// - Parameters:
    ///   - x0: The x coordinate of the start of the line
    ///   - x1: The x coordinate of the end of the line
    ///   - y0: The y coordinate of the start of the line
    ///   - y1: The y cooridnate of the end of the line
    public func line(x0: Int16, x1: Int16, y0: Int16, y1: Int16) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x0.asUInt8Array)
        data.append(contentsOf: y0.asUInt8Array)
        data.append(contentsOf: x1.asUInt8Array)
        data.append(contentsOf: y1.asUInt8Array)

        sendCommand(id: .line, withData: data)
    }
    
    /// Draw an empty rectangle at the corresponding coordinates
    /// - Parameters:
    ///   - x0: The x coordinate of the bottom left part of the rectangle
    ///   - x1: The x coordinate of the top right part of the rectangle
    ///   - y0: The y coordinate of the bottom left part of the rectangle
    ///   - y1: The y coordinate of the top right part of the rectangle
    public func rect(x0: Int16, x1: Int16, y0: Int16, y1: Int16) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x0.asUInt8Array)
        data.append(contentsOf: y0.asUInt8Array)
        data.append(contentsOf: x1.asUInt8Array)
        data.append(contentsOf: y1.asUInt8Array)

        sendCommand(id: .rect, withData: data)
    }

    /// Draw a full rectangle at the corresponding coordinates
    /// - Parameters:
    ///   - x0: The x coordinate of the bottom left part of the rectangle
    ///   - x1: The x coordinate of the top right part of the rectangle
    ///   - y0: The y coordinate of the bottom left part of the rectangle
    ///   - y1: The y coordinate of the top right part of the rectangle
    public func rectf(x0: Int16, x1: Int16, y0: Int16, y1: Int16) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x0.asUInt8Array)
        data.append(contentsOf: y0.asUInt8Array)
        data.append(contentsOf: x1.asUInt8Array)
        data.append(contentsOf: y1.asUInt8Array)

        sendCommand(id: .rectf, withData: data)
    }
    
    /// Draw an empty circle at the corresponding coordinates
    /// - Parameters:
    ///   - x: The x coordinate of the center of the circle
    ///   - y: The y coordinate of the center of the circle
    ///   - radius: The circle radius in pixels
    public func circ(x: Int16, y: Int16, radius: UInt8) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)
        data.append(radius)
        
        sendCommand(id: .circ, withData: data)
    }
    
    /// Draw a full circle at the corresponding coordinates
    /// - Parameters:
    ///   - x: The x coordinate of the center of the circle
    ///   - y: The y coordinate of the center of the circle
    ///   - radius: The circle radius in pixels
    public func circf(x: Int16, y: Int16, radius: UInt8) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)
        data.append(radius)
        
        sendCommand(id: .circf, withData: data)
    }
    
    /// Write the specified string at the specified coordinates, with rotation, font size and color
    /// - Parameters:
    ///   - x: The x coordinate of the start of the string
    ///   - y: The y coordinate of the start of the string
    ///   - rotation: The rotation of the drawn text
    ///   - font: The id of the font used to draw the string
    ///   - color: The color used to draw the string, between 0 and 15
    ///   - string: The string to draw
    public func txt(x: Int16, y: Int16, rotation: TextRotation, font: UInt8, color: UInt8, string: String) {
        var data: [UInt8] = []
        
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)
        data.append(rotation.rawValue)
        data.append(font)
        data.append(color)
        data.append(contentsOf: Array(string.utf8))
        
        sendCommand(id: .txt, withData: data)
    }
    
//    public func polyline() {
//        // TODO
//    }

    
    // MARK: - Bitmap commands

    /// List all images saved on the device.
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func imgList(_ callback: @escaping ([ImageInfo]) -> Void) {
        sendCommand(id: .imgList, withData: nil) { (commandResponseData) in
            guard commandResponseData.count % 4 == 0 else {
                print("response format error for imgList command") // TODO Raise error
                return
            }
            
            var images: [ImageInfo] = []
            var index = 1
            let chunkedData = commandResponseData.chunked(into: 4)

            for data in chunkedData {
                images.append(ImageInfo.fromCommandResponseData(data, withId: index))
                index += 1
            }
            
            callback(images)
        }
    }
    
    /// Save a 4bpp image of the specified width.
    /// - Parameter imageData: The data representing the image to save
    public func imgSave(id: UInt8, imageData: ImageData) {
        var firstChunkData: [UInt8] = [id]
        firstChunkData.append(contentsOf: imageData.size.asUInt8Array)
        firstChunkData.append(contentsOf: imageData.width.asUInt8Array)
        
        sendCommand(id: .imgSave, withData: firstChunkData)
        
        // TODO Should be using bigger chunk size (505) but not working on 3.7.4b
        let chunkedImageData = imageData.data.chunked(into: 121) // 128 - ( Header + CmdID + CmdFormat + QueryId + Length on 2 bytes + Footer)
                
        for chunk in chunkedImageData {
            sendCommand(id: .imgSave, withData: chunk) // TODO This will probably cause unhandled overflow if the image is too big
        }
    }
    
    /// Display the image corresponding to the specified id at the specified position
    /// - Parameters:
    ///   - id: The id of the image to display
    ///   - x: The x coordinate of the image to display
    ///   - y: The y coordinate of the image to display
    public func imgDisplay(id: UInt8, x: Int16, y: Int16) {
        var data: [UInt8] = [id]
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)
        sendCommand(id: .imgDisplay, withData: data)
    }

    /// Delete the specified image
    /// - Parameter id: The id of the image to delete
    public func imgDelete(id: UInt8) {
        sendCommand(id: .imgDelete, withValue: id)
    }

    /// Delete all images
    public func imgDeleteAll() {
        sendCommand(id: .imgDelete, withValue: 0xFF)
    }

    /// WARNING: NOT TESTED / NOT FULLY IMPLEMENTED
    public func imgStream(imageData: ImageData, x: Int16, y: Int16) {
        // TODO Infer size from data length
        // TODO Create command and send command
    }

    /// WARNING: NOT TESTED / NOT FULLY IMPLEMENTED
    public func imgSave1bpp(imageData: ImageData) {
        // TODO Create command and send command
    }
    
    
    // MARK: - Font commands
    
    /// WARNING: CALLBACK NOT WORKING as of 3.7.4b
    public func fontlist(_ callback: @escaping ([FontInfo]) -> Void) {
        sendCommand(id: .fontList) { (commandResponseData: [UInt8]) in
            callback(FontInfo.fromCommandResponseData(commandResponseData))
        }
    }

    /// Save a font to the specified font id
    /// - Parameters:
    ///   - id: The id of the font to save
    ///   - fontData: The encoded font data
    public func fontSave(id: UInt8, fontData: FontData) {
        // Prepend reserved 0x01 byte and font height in pixels to actual font data
        var commandData: [UInt8] = [0x01, fontData.height]
        commandData.append(contentsOf: fontData.data)
        
        var firstChunkData: [UInt8] = []
        firstChunkData.append(id)
        firstChunkData.append(contentsOf: UInt16(commandData.count).asUInt8Array)

        sendCommand(id: .fontSave, withData: firstChunkData)
        
        // TODO Should be using bigger chunk size (505) but not working on 3.7.4b
        let chunkedCommandData = commandData.chunked(into: 121) // 128 - ( Header + CmdID + CmdFormat + QueryId + Length on 2 bytes + Footer)

        for chunk in chunkedCommandData {
            sendCommand(id: .fontSave, withData: chunk) // TODO This will probably cause unhandled overflow if the image is too big
        }
    }

    /// Select font which will be used for followings txt commands
    /// - Parameter id: The id of the font to select
    public func fontSelect(id: UInt8) {
        sendCommand(id: .fontSelect, withValue: id)
    }

    /// Delete the font corresponding to the specified font id if present
    /// - Parameter id: The id of the font to delete
    public func fontDelete(id: UInt8) {
        sendCommand(id: .fontDelete, withValue: id)
    }

    /// Delete all the font
    public func fontDeleteAll() {
        sendCommand(id: .fontDelete, withValue: 0xFF)
    }

    
    // MARK: - Layout commands
    
    /// Save a new layout according to the specified layout parameters.
    /// - Parameter layout: The parameters of the layout to save
    public func layoutSave(parameters: LayoutParameters) {
        sendCommand(id: .layoutSave, withData: parameters.toCommandData())
    }

    /// Delete the specified layout
    /// - Parameter id: The id of the layout to delete
    public func layoutDelete(id: UInt8) {
        sendCommand(id: .layoutDelete, withValue: id)
    }

    /// Delete all layouts
    public func layoutDeleteAll() {
        sendCommand(id: .layoutDelete, withValue: 0xFF)
    }

    /// Display the specified layout with the specified text as its value
    /// - Parameters:
    ///   - id: The id of the layout to display
    ///   - text: The text value of the layout
    public func layoutDisplay(id: UInt8, text: String) {
        var data: [UInt8] = [id]
        data.append(contentsOf: Array(text.utf8))
        sendCommand(id: .layoutDisplay, withData: data)
    }

    /// Clear the layout area corresponding to the specified layout id
    /// - Parameter id: The id of the layout to clear
    public func layoutClear(id: UInt8) {
        sendCommand(id: .layoutClear, withValue: id)
    }

    /// Get the list of layouts
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func layoutList(_ callback: @escaping ([Int]) -> Void) {
        sendCommand(id: .layoutList) { (commandResponseData: [UInt8]) in
            var results: [Int] = []
            commandResponseData.forEach { b in
                results.append(Int(b & 0x00FF))
            }
            callback(results)
        }
    }

    /// Redefine the position of a layout. The new position is saved.
    /// - Parameters:
    ///   - id: The id of the layout to reposition
    ///   - x: The x coordinate of the new position
    ///   - y: The y coordinate of the new position
    public func layoutPosition(id: UInt8, x: UInt16, y: UInt8) {
        var data: [UInt8] = [id]
        data.append(contentsOf: x.asUInt8Array)
        data.append(y) // y is only encoded on 1 byte

        sendCommand(id: .layoutPosition, withData: data)
    }

    /// Display the specified layout at the specified position with the specified value. Position is not saved
    /// - Parameters:
    ///   - id: The id of the layout to display
    ///   - x: The x coordinate of the position of the layout
    ///   - y: The y coordinate of the position of the layout
    ///   - text: The text value of the layout
    public func layoutDisplayExtended(id: UInt8, x: UInt16, y: UInt8, text: String) {
        var data: [UInt8] = [id]
        data.append(contentsOf: x.asUInt8Array)
        data.append(y) // y is only encoded on 1 byte
        data.append(contentsOf: Array(text.utf8))
        
        sendCommand(id: .layoutDisplayExtended, withData: data)
    }

    /// Get a layout
    /// - Parameters:
    ///   - id: The id of the layout to get
    ///   - callback: A callback called asynchronously when the device answers
    public func layoutGet(id: UInt8, _ callback: @escaping (LayoutParameters) -> Void) {
        sendCommand(id: .layoutGet, withData: [id]) { (commandResponseData: [UInt8]) in
            callback(LayoutParameters.fromCommandResponseData(commandResponseData))
        }
    }
    
    
    // MARK: - Gauge commands
    
    /// Display the specified gauge with the specified value
    /// - Parameters:
    ///   - id: The gauge to display. It should have been created beforehand with the gaugeSave() command.
    ///   - value: The value of the gauge.
    public func gaugeDisplay(id: UInt8, value: UInt8) {
        sendCommand(id: .gaugeDisplay, withData: [id, value])
    }

    /// Save a gauge for the specified id with the specified parameters.
    ///
    /// ⚠ The `cfgWrite` command is required before any gauge upload.
    ///
    /// - Parameters:
    ///   - id: The id of the gauge
    ///   - x: The horizontal position of the gauge on the screen
    ///   - y: The vertical position of the gauge on the screen
    ///   - externalRadius: The radius of the outer bound of the gauge, in pixels
    ///   - internalRadius: The radius of the inner bound of the gauge, in pixels
    ///   - start: The start segment of the gauge, between 1 and 16
    ///   - end: The end segment of the gauge, between 1 and 16
    ///   - clockwise: Whether the gauge should be drawn clockwise or anti-clockwise
    public func gaugeSave(id: UInt8, x: UInt16, y: UInt16, externalRadius: UInt16, internalRadius: UInt16, start: UInt8, end: UInt8, clockwise: Bool) {
        var data: [UInt8] = [id]
        
        data.append(contentsOf: x.asUInt8Array)
        data.append(contentsOf: y.asUInt8Array)
        data.append(contentsOf: externalRadius.asUInt8Array)
        data.append(contentsOf: internalRadius.asUInt8Array)
        
        data.append(contentsOf: [start, end, clockwise ? 0x01 : 0x00])
        
        sendCommand(id: .gaugeSave, withData: data)
    }

    /// Delete the specified gauge
    /// - Parameter id: The id of the gauge to delete
    public func gaugeDelete(id: UInt8) {
        sendCommand(id: .gaugeDelete, withValue: id)
    }

    /// Delete all gauge
    public func gaugeDeleteAll() {
        sendCommand(id: .gaugeDelete, withValue: 0xFF)
    }

    /// Get the list of gauge
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func gaugeList(_ callback: @escaping ([Int]) -> Void) {
        sendCommand(id: .gaugeList) { (commandResponseData: [UInt8]) in
            var results: [Int] = []
            commandResponseData.forEach { b in
                results.append(Int(b & 0x00FF))
            }
            callback(results)
        }
    }

    /// Get a gauge
    /// - Parameters:
    ///   - id: The id of the gauge to get
    ///   - callback: A callback called asynchronously when the device answers
    public func gaugeGet(id: UInt8, _ callback: @escaping (GaugeInfo) -> Void) {
        sendCommand(id: .gaugeGet, withData: [id]) { (commandResponseData: [UInt8]) in
            callback(GaugeInfo.fromCommandResponseData(commandResponseData))
        }
    }
    
    // MARK: - Page commands
    /// Save a page
    public func pageSave(id: UInt8, layoutIds: [UInt8], xs: [Int16], ys: [UInt8]) {
        let pi = PageInfo(id, layoutIds, xs, ys)
        sendCommand(id: .pageSave, withData: pi.payload)
    }

    /// Get a page
    /// - Parameters:
    ///   - id: The id of the page to get
    ///   - callback: A callback called asynchronously when the device answers
    public func pageGet(id: UInt8, _ callback: @escaping (PageInfo) -> Void) {
        sendCommand(id: .pageGet, withData: [id]) { (commandResponseData: [UInt8]) in
            callback(PageInfo.fromCommandResponseData(commandResponseData))
        }
    }

    /// Delete a page
    public func pageDelete(id: UInt8) {
        sendCommand(id: .pageDelete, withValue: id)
    }
    
    /// Delete all pages
    public func pageDeleteAll() {
        sendCommand(id: .pageDelete, withValue: 0xFF)
    }


    /// Display a page
    public func pageDisplay(id: UInt8, texts: [String]) {
        var withData: [UInt8] = []
        texts.forEach { text in
            withData += Array(text.utf8)
        }
        sendCommand(id: .pageDisplay, withData: withData)
    }

    /// Clear a page
    public func pageClear(id: UInt8) {
        sendCommand(id: .pageClear, withValue: id)
    }

    /// List a page
    public func pageList(_ callback: @escaping ([Int]) -> Void) {
        sendCommand(id: .pageList) { (commandResponseData: [UInt8]) in
            var results: [Int] = []
            commandResponseData.forEach { b in
                results.append(Int(b & 0x00FF))
            }
            callback(results)
        }
    }
    
    
    // MARK: - Statistics commands
    /// Get number of pixel activated on display
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func pixelCount(_ callback: @escaping (Int) -> Void) {
        sendCommand(id: .pixelCount, withData: nil) { (commandResponseData: [UInt8]) in
            let pixelCount = Int.fromUInt32ByteArray(bytes: commandResponseData)
            callback(pixelCount)
        }
    }
    
    /// Set the maximum amount of pixels that can be displayed
    /// - Parameter value: The maximum amount of pixels the screen should display
    public func setPixelValue(_ value: UInt32) {
        sendCommand(id: .setPixelValue, withData: value.asUInt8Array)
    }

    /// Get total number of charging cycles
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func getChargingCounter(_ callback: @escaping (Int) -> Void) {
        sendCommand(id: .getChargingCounter, withData: nil) { (commandResponseData: [UInt8]) in
            let chargingCount = Int.fromUInt32ByteArray(bytes: commandResponseData)
            callback(chargingCount)
        }
    }

    /// Get total number of charging minutes
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func getChargingTime(_ callback: @escaping (Int) -> Void) {
        sendCommand(id: .getChargingTime, withData: nil) { (commandResponseData: [UInt8]) in
            let chargingTime = Int.fromUInt32ByteArray(bytes: commandResponseData)
            callback(chargingTime)
        }
    }

    /// Get the maximum number of pixel activated
    /// - Parameter callback: A callback called asynchronously when the device answers
    public func getMaxPixelValue(_ callback: @escaping (Int) -> Void) {
        // Not working on 3.7.4b. Glasses answer for charging counter instead...
        sendCommand(id: .getMaxPixelValue, withData: nil) { (commandResponseData: [UInt8]) in
            let maxPixelValue = Int.fromUInt32ByteArray(bytes: commandResponseData)
            callback(maxPixelValue)
        }
    }

    /// Reset charging counter and charging time values
    public func resetChargingParam() {
        sendCommand(id: .resetChargingParam)
    }
    
    
    // MARK: - Configuration commands
    
    /// Write configuration. The configuration id is used to track which config is on the device
    /// - Parameters:
    ///   - number: The configuration number
    ///   - configID: The configuration ID
    public func writeConfigID(configuration: Configuration) {
        sendCommand(id: .wConfigID, withData: configuration.toCommandData())
    }

    /// Read configuration.
    /// - Parameter number: The number of the configuration to read
    ///   - callback:  A callback called asynchronously when the device answers
    public func readConfigID(number: UInt8, callback: @escaping (Configuration) -> Void) {
        sendCommand(id: .rConfigID, withData: [number]) { (commandResponseData) in
            callback(Configuration.fromCommandResponseData(commandResponseData))
        }
    }
    
    /// Set current configuration to display images, layouts and fonts.
    /// - Parameter number: The number of the configuration to read
    public func setConfigID(number: UInt8) {
        sendCommand(id: .setConfigID, withValue: number)
    }
    
    /// Write a new configuration
    public func cfgWrite(name: String, version: Int, password: String) {
        let withData = Array(name.utf8) + version.asUInt8Array + Array(password.utf8)
        sendCommand(id: .cfgWrite, withData: withData)
    }

    /// Read a configuration
    public func cfgRead(name: String, callback: @escaping (ConfigurationElementsInfo) -> Void) {
        sendCommand(id: .cfgRead, withData: Array(name.utf8)) { (commandResponseData) in
            callback(ConfigurationElementsInfo.fromCommandResponseData(commandResponseData))
        }
    }

    /// Set the configuration
    public func cfgSet(name: String) {
        sendCommand(id: .cfgSet, withData: Array(name.utf8))
    }

    /// List of configuration
    public func cfgList(callback: @escaping ([ConfigurationDescription]) -> Void) {
        sendCommand(id: .cfgList) { (commandResponseData) in
            callback(ConfigurationDescription.fromCommandResponseData(commandResponseData))
        }
    }

    /// Rename a configuration
    public func cfgRename(oldName: String, newName: String, password: String) {
        let withData = Array(oldName.utf8) + Array(newName.utf8) + Array(password.utf8)
        sendCommand(id: .cfgRename, withData: withData)
    }

    /// Delete a configuration
    public func cfgDelete(name: String) {
        sendCommand(id: .cfgDelete, withData: Array(name.utf8))
    }

    /// Delete least used configuration
    public func cfgDeleteLessUsed() {
        sendCommand(id: .cfgDeleteLessUsed)
    }

    /// get available free space
    public func cfgFreeSpace(callback: @escaping (FreeSpace) -> Void) {
        sendCommand(id: .cfgFreeSpace) { (commandResponseData) in
            callback(FreeSpace.fromCommandResponseData(commandResponseData))
        }
    }

    /// get number of configuration
    public func cfgGetNb(callback: @escaping (Int) -> Void) {
        sendCommand(id: .cfdGetNb) { (commandResponseData) in
            callback(Int(commandResponseData[0]))
        }
    }
    
    
    // MARK: - Notifications
    
    /// Subscribe to battery level notifications. The specified callback will return the battery value about once every thirty seconds.
    /// - Parameter batteryLevelUpdateCallback: A callback called asynchronously when the device sends a battery level notification.
    public func subscribeToBatteryLevelNotifications(onBatteryLevelUpdate batteryLevelUpdateCallback: @escaping (Int) -> (Void)) {
        peripheral.setNotifyValue(true, for: batteryLevelCharacteristic!)
        self.batteryLevelUpdateCallback = batteryLevelUpdateCallback
    }
    
    /// Subscribe to flow control notifications. The specified callback will be called whenever the flow control state changes.
    /// - Parameter flowControlUpdateCallback: A callback called asynchronously when the device sends a flow control update.
    public func subscribeToFlowControlNotifications(onFlowControlUpdate flowControlUpdateCallback: @escaping (FlowControlState) -> (Void)) {
        peripheral.setNotifyValue(true, for: flowControlCharacteristic!)
        self.flowControlUpdateCallback = flowControlUpdateCallback
    }
    
    /// Subscribe to sensor interface notifications. The specified callback will be called whenever a gesture has been detected.
    /// - Parameter sensorInterfaceTriggeredCallback: A callback called asynchronously when the device detects a gesture.
    public func subscribeToSensorInterfaceNotifications(onSensorInterfaceTriggered sensorInterfaceTriggeredCallback: @escaping () -> (Void)) {
        peripheral.setNotifyValue(true, for: sensorInterfaceCharacteristic!)
        self.sensorInterfaceTriggeredCallback = sensorInterfaceTriggeredCallback
    }
    
    /// Unsubscribe from battery level notifications.
    public func unsubscribeFromBatteryLevelNotifications() {
        peripheral.setNotifyValue(false, for: batteryLevelCharacteristic!)
        batteryLevelUpdateCallback = nil
    }
    
    /// Unsubscribe from flow control notifications.
    public func unsubscribeFromFlowControlNotifications() {
        peripheral.setNotifyValue(false, for: flowControlCharacteristic!)
        flowControlUpdateCallback = nil
    }
    
    /// Unsubscribe from sensor interface notifications.
    public func unsubscribeFromSensorInterfaceNotifications() {
        peripheral.setNotifyValue(false, for: sensorInterfaceCharacteristic!)
        sensorInterfaceTriggeredCallback = nil
    }

    
    // MARK: - CBPeripheralDelegate

    /// Internal class to allow Glasses to not inherit from NSObject and to hide CBPeripheralDelegate methods
    internal class PeripheralDelegate: NSObject, CBPeripheralDelegate {
        
        weak var parent: Glasses?

        // MARK: - CBPheripheralDelegate

        public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
            guard error == nil else {
                print("error while updating notification state : \(error!.localizedDescription) for characteristic: \(characteristic.uuid)")
                return
            }

    //        print("peripheral did update notification state for characteristic: ", characteristic)
        }
        
        public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            guard error == nil else {
                // TODO Raise error
                print("error while updating value : \(error!.localizedDescription) for characteristic: \(characteristic.uuid)")
                return
            }

            //print("peripheral did update value for characteristic: ", characteristic.uuid)
            
            switch characteristic.uuid {
            case CBUUID.ActiveLookTxCharacteristic:

                if let data = characteristic.value {
                    parent?.handleTxNotification(withData: data)
                }

            case CBUUID.BatteryLevelCharacteristic:
                parent?.batteryLevelUpdateCallback?(characteristic.valueAsInt)
            case CBUUID.ActiveLookFlowControlCharacteristic:

                if let flowControlState = FlowControlState(rawValue: characteristic.valueAsInt) {
                    parent?.flowControlUpdateCallback?(flowControlState)
                }

            case CBUUID.ActiveLookSensorInterfaceCharacteristic:
                parent?.sensorInterfaceTriggeredCallback?()
            default:
                break
            }
        }
        
        public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
            guard error == nil else {
                // TODO Raise error
                print("error while writing value : \(error!.localizedDescription) for characteristic: \(characteristic.uuid)")
                return
            }

            //print("peripheral did write value for characteristic: ", characteristic.uuid)
        }
    }
}
