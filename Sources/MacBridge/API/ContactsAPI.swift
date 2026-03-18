import BridgeCore
import Contacts
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "contacts")

class ContactsAPI {
    private let store = CNContactStore()
    private var hasAccess = false

    init() {
        Task { await requestAccess() }
    }

    private func requestAccess() async {
        do {
            hasAccess = try await store.requestAccess(for: .contacts)
            if hasAccess {
                log.info("Access granted")
            } else {
                log.warning("Access denied")
            }
        } catch {
            log.error("Failed to request access: \(error)")
        }
    }

    // MARK: - Health

    func healthCheck() -> [String: Any] {
        buildHealthResult(
            app: "contacts-bridge",
            status: hasAccess ? "ok" : "error",
            details: ["hasAccess": hasAccess]
        )
    }

    private func ensureAccess() throws {
        guard hasAccess else {
            throw NSError(
                domain: "ContactsBridge", code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Contacts access not granted"])
        }
    }

    func getContacts(search: String?, limit: Int, offset: Int) async throws -> [[String: Any]] {
        try ensureAccess()

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        var contacts: [CNContact] = []
        let needed = limit + offset

        if let searchTerm = search, !searchTerm.isEmpty {
            let predicate = CNContact.predicateForContacts(matchingName: searchTerm)
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        } else {
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            try store.enumerateContacts(with: request) { contact, stop in
                contacts.append(contact)
                if contacts.count >= needed {
                    stop.pointee = true
                }
            }
        }

        return Array(contacts.dropFirst(offset).prefix(limit).map { contactToDict($0) })
    }

    func getContact(id: String) async throws -> [String: Any]? {
        try ensureAccess()

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor,
        ]

        do {
            let contact = try store.unifiedContact(
                withIdentifier: id, keysToFetch: keysToFetch)
            return contactToDict(contact, fullDetails: true)
        } catch {
            return nil
        }
    }

    func searchContacts(email: String?, phone: String?) async throws -> [[String: Any]] {
        try ensureAccess()

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        var results: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        try store.enumerateContacts(with: request) { contact, _ in
            if let email = email {
                let hasEmail = contact.emailAddresses.contains { emailAddr in
                    emailAddr.value as String == email
                        || (emailAddr.value as String).lowercased().contains(email.lowercased())
                }
                if hasEmail {
                    results.append(contact)
                    return
                }
            }

            if let phone = phone {
                let hasPhone = contact.phoneNumbers.contains { phoneNumber in
                    phoneNumber.value.stringValue.contains(phone)
                }
                if hasPhone {
                    results.append(contact)
                }
            }
        }

        return results.map { contactToDict($0) }
    }

    func createContact(
        firstName: String, lastName: String?, middleName: String?,
        nickname: String?, organization: String?, department: String?,
        jobTitle: String?, email: String?, phone: String?,
        birthday: String?, note: String?
    ) async throws -> String {
        try ensureAccess()

        let contact = CNMutableContact()
        contact.givenName = firstName
        if let lastName { contact.familyName = lastName }
        if let middleName { contact.middleName = middleName }
        if let nickname { contact.nickname = nickname }
        if let organization { contact.organizationName = organization }
        if let department { contact.departmentName = department }
        if let jobTitle { contact.jobTitle = jobTitle }
        if let note { contact.note = note }
        if let email {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString)
            ]
        }
        if let phone {
            contact.phoneNumbers = [
                CNLabeledValue(
                    label: CNLabelPhoneNumberMobile,
                    value: CNPhoneNumber(stringValue: phone))
            ]
        }
        if let birthday { contact.birthday = parseBirthday(birthday) }

        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)
        try store.execute(saveRequest)

        return contact.identifier
    }

    func updateContact(
        id: String, firstName: String?, lastName: String?, middleName: String?,
        nickname: String?, organization: String?, department: String?,
        jobTitle: String?, email: String?, phone: String?,
        birthday: String?, note: String?
    ) async throws -> [String: Any] {
        try ensureAccess()

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNoteKey as CNKeyDescriptor,
        ]

        let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keysToFetch)
        let mutable = contact.mutableCopy() as! CNMutableContact

        if let firstName { mutable.givenName = firstName }
        if let lastName { mutable.familyName = lastName }
        if let middleName { mutable.middleName = middleName }
        if let nickname { mutable.nickname = nickname }
        if let organization { mutable.organizationName = organization }
        if let department { mutable.departmentName = department }
        if let jobTitle { mutable.jobTitle = jobTitle }
        if let note { mutable.note = note }
        if let email {
            mutable.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString)
            ]
        }
        if let phone {
            mutable.phoneNumbers = [
                CNLabeledValue(
                    label: CNLabelPhoneNumberMobile,
                    value: CNPhoneNumber(stringValue: phone))
            ]
        }
        if let birthday { mutable.birthday = parseBirthday(birthday) }

        let saveRequest = CNSaveRequest()
        saveRequest.update(mutable)
        try store.execute(saveRequest)
        return ["updated": true]
    }

    func deleteContacts(ids: [String]) async throws -> Int {
        try ensureAccess()

        let keysToFetch: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor]
        var deleted = 0
        for id in ids {
            do {
                let contact = try store.unifiedContact(
                    withIdentifier: id, keysToFetch: keysToFetch)
                let mutable = contact.mutableCopy() as! CNMutableContact
                let saveRequest = CNSaveRequest()
                saveRequest.delete(mutable)
                try store.execute(saveRequest)
                deleted += 1
            } catch {
                log.error("Failed to delete contact \(id): \(error)")
            }
        }
        return deleted
    }

    private func parseBirthday(_ str: String) -> DateComponents? {
        let parts = str.split(separator: "-")
        guard parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    private func contactToDict(_ contact: CNContact, fullDetails: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [
            "id": contact.identifier,
            "name": CNContactFormatter.string(from: contact, style: .fullName) ?? "",
            "firstName": contact.givenName,
            "lastName": contact.familyName,
            "organization": contact.organizationName,
            "jobTitle": contact.jobTitle,
        ]

        let emails = contact.emailAddresses.map { emailAddr -> [String: String] in
            [
                "label": CNLabeledValue<NSString>.localizedString(forLabel: emailAddr.label ?? ""),
                "value": emailAddr.value as String,
            ]
        }
        dict["emails"] = emails

        let phones = contact.phoneNumbers.map { phoneNumber -> [String: String] in
            [
                "label": CNLabeledValue<CNPhoneNumber>.localizedString(
                    forLabel: phoneNumber.label ?? ""),
                "value": phoneNumber.value.stringValue,
            ]
        }
        dict["phones"] = phones

        if fullDetails {
            dict["nickname"] = contact.nickname
            dict["department"] = contact.departmentName
            dict["note"] = contact.note

            if let birthday = contact.birthday {
                let dateComponents = birthday
                if let year = dateComponents.year,
                    let month = dateComponents.month,
                    let day = dateComponents.day
                {
                    dict["birthday"] =
                        "\(year)-\(String(format: "%02d", month))-\(String(format: "%02d", day))"
                }
            }

            let addresses = contact.postalAddresses.map { addressValue -> [String: Any] in
                let address = addressValue.value
                return [
                    "label": CNLabeledValue<CNPostalAddress>.localizedString(
                        forLabel: addressValue.label ?? ""),
                    "street": address.street,
                    "city": address.city,
                    "state": address.state,
                    "postalCode": address.postalCode,
                    "country": address.country,
                ]
            }
            dict["addresses"] = addresses
        }

        return dict
    }
}
