/**
* Copyright IBM Corporation 2016, 2017
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
**/

import Foundation
import Configuration
import CloudFoundryEnv
import LoggerAPI
import Yaml

public struct MetricsTrackerClient {
  let configMgr: ConfigurationManager
  let repository: String
  var organization: String?
  var codeVersion: String?

  public init(configMgr: ConfigurationManager, repository: String, organization: String? = "IBM", codeVersion: String? = nil) {
    self.repository = repository
    self.codeVersion = codeVersion
    self.configMgr = configMgr
    self.organization = organization
  }

  public init(repository: String, organization: String? = "IBM", codeVersion: String? = nil) {
    let configMgr = ConfigurationManager()
    configMgr.load(.environmentVariables)
    self.init(configMgr: configMgr, repository: repository, organization: organization, codeVersion: codeVersion)
  }

  /// Sends off HTTP post request to tracking service, simply logging errors on failure
  public func track() {
    Log.verbose("About to construct HTTP request for metrics-tracker-service...")
    if let trackerJson = buildTrackerJson(configMgr: configMgr),
    let jsonData = try? JSONSerialization.data(withJSONObject: trackerJson) {
      let jsonStr = String(data: jsonData, encoding: .utf8)
      Log.verbose("JSON payload for metrics-tracker-service is: \(String(describing: jsonStr))")
      // Build URL instance
      guard let url = URL(string: "https://metrics-tracker.mybluemix.net:443/api/v1/track") else {
        Log.verbose("Failed to create URL object to connect to metrics-tracker-service...")
        return
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
      request.httpBody = jsonData

      // Build task for request
      let requestTask = URLSession(configuration: .default).dataTask(with: request) {
        data, response, error in

        guard let httpResponse = response as? HTTPURLResponse else {
          Log.error("Failed to send tracking data to metrics-tracker-service: \(String(describing: error))")
          return
        }

        Log.info("HTTP response code: \(httpResponse.statusCode)")
        // OK = 200, CREATED = 201
        if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
          if let data = data, let jsonResponse = try? JSONSerialization.jsonObject(with: data, options: []) {
             Log.info("metrics-tracker-service response: \(jsonResponse)")

          } else {
            Log.error("Bad JSON payload received from metrics-tracker-service.")
          }
        } else {
          Log.error("Failed to send tracking data to metrics-tracker-service.")
        }
      }
      Log.verbose("Successfully built HTTP request options for metrics-tracker-service.")
      requestTask.resume()
      Log.verbose("Sent HTTP request to metrics-tracker-service...")
    } else {
      Log.verbose("Failed to build valid JSON payload for deployment tracker... maybe running locally and not on the cloud?")
    }
  }

  /// Helper method to build Json in a valid format for tracking service
  ///
  /// - parameter configMgr: application environment to pull Bluemix app data from
  ///
  /// - returns: JSON, assuming we have access to application info
  public func buildTrackerJson(configMgr: ConfigurationManager) -> [String:Any]? {
    var jsonEvent: [String:Any] = [:]
    var org = "IBM"
    if let organization = self.organization {
      org = organization
    }
    let urlString = "https://raw.githubusercontent.com/" + org + "/" + repository + "/master/repository.yaml"
    Log.info(urlString)
    guard let url = URL(string: urlString) else {
        Log.info("Failed to create URL object to connect to the github repository...")
        return nil
      }
    var yaml = ""
    var request = URLRequest(url: url)
    let requestTask = URLSession(configuration: .default).dataTask(with: request) { (yamldata, response, error) in
    guard let httpResponse = response as? HTTPURLResponse else {
      Log.error("Failed to send tracking data to metrics-tracker-service: \(String(describing: error))")
      return
    }
    Log.info("HTTP response code: \(httpResponse.statusCode)")
    if let yamlData = yamldata, let jsonResponse = try? JSONSerialization.jsonObject(with: yamlData, options: []) { 
         Log.info("data is \(jsonResponse)")
         yaml = jsonResponse
         }
    }
    requestTask.resume()

    Log.info("yaml is \(yaml)")

    Log.verbose("Preparing dictionary payload for metrics-tracker-service...")
    let dateFormatter = DateFormatter()
    #if os(OSX)
    //dateFormatter.calendar = Calendar(identifier: .iso8601)
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    #else
    //dateFormatter.calendar = Calendar(identifier: .iso8601)
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(abbreviation: "GMT")
    #endif
    dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSX"
    jsonEvent["date_sent"] = dateFormatter.string(from: Date())

    if let codeVersion = self.codeVersion {
      jsonEvent["code_version"] = codeVersion
    }
    jsonEvent["runtime"] = "swift"
    if let vcapApplication = configMgr.getApp() {

    jsonEvent["application_name"] = vcapApplication.name
    jsonEvent["space_id"] = vcapApplication.spaceId
    jsonEvent["application_id"] = vcapApplication.id
    jsonEvent["application_version"] = vcapApplication.version
    jsonEvent["application_uris"] = vcapApplication.uris
    jsonEvent["instance_index"] = vcapApplication.instanceIndex

    Log.verbose("Verifying services bound to application...")
    let services = configMgr.getServices()
    if services.count > 0 {
      var serviceDictionary = [String: Any]()
      for (_, service) in services {
        if var serviceStats = serviceDictionary[service.label] as? [String: Any] {
          if let count = serviceStats["count"] as? Int {
            serviceStats["count"] = count + 1
          }
          if var plans = serviceStats["plans"] as? [String] {
            if !plans.contains(service.plan) { plans.append(service.plan) }
            serviceStats["plans"] = plans
          }
          serviceDictionary[service.label] = serviceStats
        } else {
          var newService = [String: Any]()
          newService["count"] = 1
          newService["plans"] = service.plan.components(separatedBy: ", ")
          serviceDictionary[service.label] = newService
        }
      }
      jsonEvent["bound_vcap_services"] = serviceDictionary
    }
  }

    do {
    let journey_metric = try Yaml.load(yaml)
    var metrics = [String: Any]()
    metrics["repository_id"] = journey_metric["id"]
    metrics["target_runtimes"] = journey_metric["runtimes"]
    metrics["target_services"] = journey_metric["services"]
    metrics["event_id"] = journey_metric["event_id"]
    metrics["event_organizer"] = journey_metric["event_organizer"]
    jsonEvent["config"] = metrics
    } catch {
      Log.info("repository.yaml not exist.")
    }

    Log.verbose("Finished preparing dictionary payload for metrics-tracker-service.")
    Log.verbose("Dictionary payload for metrics-tracker-service is: \(jsonEvent)")
    return jsonEvent
  }

}
