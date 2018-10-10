#!/usr/bin/env xcrun swift
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation

/// Helper class to print to the standard error easier.
class StandardErrorOutputStream: TextOutputStream
{
    func write(_ string: String)
    {
        let stderr = FileHandle.standardError
        if let data = string.data(using: String.Encoding.utf8)
        {
            stderr.write(data)
        }
    }
}

var std_err = StandardErrorOutputStream()

public class SimTestCtl {

    let simulatorIdString: String
    let device: AnyObject

    // Path to the private Simulator framework. Assumed to be the standard location.
    private static let coreSimulatorFrameworkPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework"
    private static let defaultDeveloperDirectoryPath = "/Applications/Xcode.app/Contents/Developer"

    public init(simulatorIdString: String) throws {
        self.simulatorIdString = simulatorIdString
        self.device = try SimTestCtl.findSimDevice(simulatorIdString: simulatorIdString)
    }
    
    public enum SimTestCtlError: Error {
        
        case coreSimulatorLoadingFailure(String)
        case serviceContextCreationFailed(String)
        case coreSimulatorInternalError(String)
        case parameterError(String)
        
        var code: Int {
            switch self {
            case .coreSimulatorLoadingFailure:
                return 1
            case .serviceContextCreationFailed:
                return 2
            case .coreSimulatorInternalError:
                return 3
            case .parameterError:
                return 4
            }
        }
        
        var message: String {
            switch self {
            case .coreSimulatorLoadingFailure(let msg):
                return msg
            case .serviceContextCreationFailed(let msg):
                return msg
            case .coreSimulatorInternalError(let msg):
                return msg
            case .parameterError(let msg):
                return msg
            }
        
         }
    }
    
    /// Helper method to get the booted SimDevice instance for the given Simulator ID.
    /// (An error is thrown is the Simulator is found, but it's not booted)
    /// The method first tries to load the private Apple CoreSimulator framework.
    /// It does so in the same way as FBSimulatorControl does (see: https://github.com/facebook/FBSimulatorControl)
    /// - Parameter simulatorIdString: The Simulator ID to use.
    /// - Returns: The relevant booted SimDevice
    /// - Throws: SimTestCtlError
    private static func findSimDevice(simulatorIdString: String) throws -> AnyObject {
        let simServiceClassName = "SimServiceContext"

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: SimTestCtl.coreSimulatorFrameworkPath, isDirectory: &isDirectory) else {
            throw SimTestCtlError.coreSimulatorLoadingFailure("Can't find \(SimTestCtl.coreSimulatorFrameworkPath)")
        }
        
        guard let bundle = Bundle(path: SimTestCtl.coreSimulatorFrameworkPath) else {
            throw SimTestCtlError.coreSimulatorLoadingFailure("Can't create bundle at path: \(SimTestCtl.coreSimulatorFrameworkPath)")
        }
        
        do {
            try bundle.loadAndReturnError()
        } catch let error {
            throw SimTestCtlError.coreSimulatorLoadingFailure("Can't load bundle at path: \(SimTestCtl.coreSimulatorFrameworkPath), error: \(error)")
        }
        
        guard let serviceContextClass = simServiceClassName.withCString({
            objc_lookUpClass($0)
        }) else {
            throw SimTestCtlError.serviceContextCreationFailed("Can't find class: \(simServiceClassName)")
        }
        
        func getServiceContext(serviceContextClass: AnyClass, developerDirPath: String) -> AnyObject? {
            if (serviceContextClass as AnyObject).responds(to: Selector(("sharedServiceContextForDeveloperDir:error:"))) {
                
                return (serviceContextClass as AnyObject).perform(Selector(("sharedServiceContextForDeveloperDir:error:")),
                                                                  with: developerDirPath as NSString,
                                                                  with: nil)?.takeRetainedValue()
            }
            
            return nil
        }
        
        func getDeviceSet(serviceContext: AnyObject) -> AnyObject? {
            if serviceContext.responds(to: Selector(("defaultDeviceSetWithError:"))) {
                if let wrappedDeviceSet = serviceContext.perform(Selector(("defaultDeviceSetWithError:")), with: nil) {
                    return wrappedDeviceSet.takeRetainedValue()
                }
            }
            return nil
        }

        var developerDirectoryPath = defaultDeveloperDirectoryPath
        if let environmentDeveloperDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            developerDirectoryPath = environmentDeveloperDir
        }
        
        guard let serviceContext = getServiceContext(serviceContextClass: serviceContextClass, developerDirPath: developerDirectoryPath) else {
            throw SimTestCtlError.coreSimulatorInternalError("Can't instantiate service context for path: \(developerDirectoryPath)")
        }
        
        guard let deviceSet = getDeviceSet(serviceContext: serviceContext) else {
            throw SimTestCtlError.coreSimulatorInternalError("Can't get the default device set from service context: \(serviceContext)")
        }
        
        guard let devicesDict = deviceSet.perform(Selector(("devicesByUDID")))?.takeRetainedValue() as? [UUID: AnyObject] else {
            throw SimTestCtlError.coreSimulatorInternalError("Can't get devices from deviceSet: \(deviceSet)")
        }
        
        guard let simulatorUUID = UUID(uuidString: simulatorIdString) else {
            throw SimTestCtlError.parameterError("Invalid Simulator ID: \(simulatorIdString)")
        }
        
        guard let simDevice = devicesDict[simulatorUUID] else {
            throw SimTestCtlError.parameterError("Can't find Simulator with ID: \(simulatorIdString)")
        }
        
        typealias getStateIMP = @convention(c) (AnyObject, Selector) -> UInt64
        let getStateSelector = Selector(("state"))
        guard let getStateMethod = simDevice.method(for: getStateSelector) else {
            throw SimTestCtlError.coreSimulatorInternalError("Can't get state of Simulator device: \(simDevice)")
        }
        
        let getStateFunc = unsafeBitCast(getStateMethod, to: getStateIMP.self)
        let state = getStateFunc(simDevice, getStateSelector)
        guard state == 3 else {
            throw SimTestCtlError.parameterError("Simulator not booted: \(simDevice)")
        }
        
        return simDevice
    }

    /// Helper method to change the biometrics enrollment state of the Simulator device
    /// It does this by invoking two private methods on the SimDevice.
    /// For SimDevice APIs see: https://github.com/facebook/FBSimulatorControl/blob/master/PrivateHeaders/CoreSimulator/SimDevice.h
    /// - Parameter enrolled: Boolean flag to either enroll or unenroll the biometrics
    /// - Throws: SimTestCtlError in case of failure.
    func sendEnrollmentState(enrolled: Bool) throws {
        typealias setStateIMP = @convention(c) (AnyObject, Selector, UInt64, Any?, Any?) -> Bool
        typealias postIMP = @convention(c) (AnyObject, Selector, Any?, Any?) -> Bool
        let setStateSelector = Selector(("darwinNotificationSetState:name:error:"))
        let postSelector = Selector(("postDarwinNotification:error:"))
        let enrollmentStateNotificationNameString = "com.apple.BiometricKit.enrollmentChanged" as NSString
        
        guard let setStateMethod = device.method(for: setStateSelector),
            let postMethod = device.method(for: postSelector) else {
            throw SimTestCtlError.coreSimulatorInternalError("Can't resolve SimDevice Darwin notification APIs")
        }
        
        let setStateFunc = unsafeBitCast(setStateMethod, to: setStateIMP.self)
        let postFunc = unsafeBitCast(postMethod, to: postIMP.self)
        guard setStateFunc(device, setStateSelector, enrolled ? 1 : 0, enrollmentStateNotificationNameString, nil) else {
            throw SimTestCtlError.coreSimulatorInternalError("darwinNotificationSetState failed")
        }
        
        guard postFunc(device, postSelector, enrollmentStateNotificationNameString, nil) else {
            throw SimTestCtlError.coreSimulatorInternalError("postDarwinNotification failed")
        }
    }
}


func printUsage() {
    print("Usage: \(CommandLine.arguments[0]) <enroll|unenroll> <SIMULATOR_ID>", to:&std_err)
}

if CommandLine.argc < 2
{
    printUsage()
    exit(1)
}

let simulatorIdString: String
if CommandLine.argc == 2 {
    // Try to get the Simulator ID from Environment
    guard let environmentSimulatorId = ProcessInfo.processInfo.environment["SIMULATOR_ID"] else {
        print("Simulator ID is not specified on the command line, and SIMULATOR_ID environment variable is also not set ", to: &std_err)
        exit(1)
    }
    simulatorIdString = environmentSimulatorId
} else {
    simulatorIdString = CommandLine.arguments[2]
}

let enroll: Bool
if CommandLine.arguments[1] == "enroll" {
    enroll = true
} else if CommandLine.arguments[1] == "unenroll" {
    enroll = false
} else {
    printUsage()
    exit(1)
}

do {
    let simTestCtl = try SimTestCtl(simulatorIdString: simulatorIdString)
    try simTestCtl.sendEnrollmentState(enrolled: enroll)
} catch let error {
    print("Error: \(error)")
    exit(1)
}

