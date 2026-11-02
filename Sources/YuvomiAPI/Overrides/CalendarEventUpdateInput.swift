// Handgeschrieben statt generiert, siehe typeOverrides in openapi-generator-config.yaml.
// Felder wie Components.Schemas.CalendarEventUpdateInput in Spec/openapi.json.

/// Body von `PUT /calendar/{id}`. Was fehlt, bleibt wie gespeichert; `null` in `end_datetime`, `description`, `location` und `color` leert.
///
/// Felder, die `null` annehmen, sind ein `Patch`; die übrigen werden bei `nil` weggelassen.
/// `assigned_to` geht immer als Liste. Die Spec erlaubt auch eine einzelne Zahl, die App braucht sie nicht.
struct CalendarEventUpdateInput: Codable, Hashable, Sendable {
    var title: String? = nil
    var description: Patch<String> = .unset
    var startDatetime: String? = nil
    var endDatetime: Patch<String> = .unset
    var allDay: Bool? = nil
    var location: Patch<String> = .unset
    var color: Patch<String> = .unset
    var icon: String? = nil
    var assignedTo: Patch<[Int]> = .unset
    var visibility: String? = nil
    var countdown: Bool? = nil
    var attachmentName: Patch<String> = .unset
    var attachmentData: Patch<String> = .unset
    var removeAttachment: Bool? = nil
    var documentFolderName: String? = nil
    var documentName: String? = nil
    var documentDescription: Patch<String> = .unset
    var targetGoogleCalendarId: Patch<String> = .unset
    var targetCaldavAccountId: Patch<Int> = .unset
    var targetCaldavCalendarUrl: Patch<String> = .unset
    var targetOutlookAccountId: Patch<Int> = .unset
    var targetOutlookCalendarId: Patch<String> = .unset
    var recurrenceRule: Patch<String> = .unset
    var localCalendarId: Int? = nil
    var confirmedOrphanCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case startDatetime = "start_datetime"
        case endDatetime = "end_datetime"
        case allDay = "all_day"
        case location
        case color
        case icon
        case assignedTo = "assigned_to"
        case visibility
        case countdown
        case attachmentName = "attachment_name"
        case attachmentData = "attachment_data"
        case removeAttachment = "remove_attachment"
        case documentFolderName = "document_folder_name"
        case documentName = "document_name"
        case documentDescription = "document_description"
        case targetGoogleCalendarId = "target_google_calendar_id"
        case targetCaldavAccountId = "target_caldav_account_id"
        case targetCaldavCalendarUrl = "target_caldav_calendar_url"
        case targetOutlookAccountId = "target_outlook_account_id"
        case targetOutlookCalendarId = "target_outlook_calendar_id"
        case recurrenceRule = "recurrence_rule"
        case localCalendarId = "local_calendar_id"
        case confirmedOrphanCount = "confirmed_orphan_count"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(startDatetime, forKey: .startDatetime)
        try container.encode(endDatetime, forKey: .endDatetime)
        try container.encodeIfPresent(allDay, forKey: .allDay)
        try container.encode(location, forKey: .location)
        try container.encode(color, forKey: .color)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(assignedTo, forKey: .assignedTo)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        try container.encodeIfPresent(countdown, forKey: .countdown)
        try container.encode(attachmentName, forKey: .attachmentName)
        try container.encode(attachmentData, forKey: .attachmentData)
        try container.encodeIfPresent(removeAttachment, forKey: .removeAttachment)
        try container.encodeIfPresent(documentFolderName, forKey: .documentFolderName)
        try container.encodeIfPresent(documentName, forKey: .documentName)
        try container.encode(documentDescription, forKey: .documentDescription)
        try container.encode(targetGoogleCalendarId, forKey: .targetGoogleCalendarId)
        try container.encode(targetCaldavAccountId, forKey: .targetCaldavAccountId)
        try container.encode(targetCaldavCalendarUrl, forKey: .targetCaldavCalendarUrl)
        try container.encode(targetOutlookAccountId, forKey: .targetOutlookAccountId)
        try container.encode(targetOutlookCalendarId, forKey: .targetOutlookCalendarId)
        try container.encode(recurrenceRule, forKey: .recurrenceRule)
        try container.encodeIfPresent(localCalendarId, forKey: .localCalendarId)
        try container.encodeIfPresent(confirmedOrphanCount, forKey: .confirmedOrphanCount)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decode(Patch<String>.self, forKey: .description)
        startDatetime = try container.decodeIfPresent(String.self, forKey: .startDatetime)
        endDatetime = try container.decode(Patch<String>.self, forKey: .endDatetime)
        allDay = try container.decodeIfPresent(Bool.self, forKey: .allDay)
        location = try container.decode(Patch<String>.self, forKey: .location)
        color = try container.decode(Patch<String>.self, forKey: .color)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        assignedTo = try container.decode(Patch<[Int]>.self, forKey: .assignedTo)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        countdown = try container.decodeIfPresent(Bool.self, forKey: .countdown)
        attachmentName = try container.decode(Patch<String>.self, forKey: .attachmentName)
        attachmentData = try container.decode(Patch<String>.self, forKey: .attachmentData)
        removeAttachment = try container.decodeIfPresent(Bool.self, forKey: .removeAttachment)
        documentFolderName = try container.decodeIfPresent(String.self, forKey: .documentFolderName)
        documentName = try container.decodeIfPresent(String.self, forKey: .documentName)
        documentDescription = try container.decode(Patch<String>.self, forKey: .documentDescription)
        targetGoogleCalendarId = try container.decode(Patch<String>.self, forKey: .targetGoogleCalendarId)
        targetCaldavAccountId = try container.decode(Patch<Int>.self, forKey: .targetCaldavAccountId)
        targetCaldavCalendarUrl = try container.decode(Patch<String>.self, forKey: .targetCaldavCalendarUrl)
        targetOutlookAccountId = try container.decode(Patch<Int>.self, forKey: .targetOutlookAccountId)
        targetOutlookCalendarId = try container.decode(Patch<String>.self, forKey: .targetOutlookCalendarId)
        recurrenceRule = try container.decode(Patch<String>.self, forKey: .recurrenceRule)
        localCalendarId = try container.decodeIfPresent(Int.self, forKey: .localCalendarId)
        confirmedOrphanCount = try container.decodeIfPresent(Int.self, forKey: .confirmedOrphanCount)
    }
}

extension CalendarEventUpdateInput {
    init(
        title: String? = nil,
        description: Patch<String> = .unset,
        startDatetime: String? = nil,
        endDatetime: Patch<String> = .unset,
        allDay: Bool? = nil,
        location: Patch<String> = .unset,
        color: Patch<String> = .unset,
        icon: String? = nil,
        assignedTo: Patch<[Int]> = .unset,
        visibility: String? = nil,
        countdown: Bool? = nil,
        attachmentName: Patch<String> = .unset,
        attachmentData: Patch<String> = .unset,
        removeAttachment: Bool? = nil,
        documentFolderName: String? = nil,
        documentName: String? = nil,
        documentDescription: Patch<String> = .unset,
        targetGoogleCalendarId: Patch<String> = .unset,
        targetCaldavAccountId: Patch<Int> = .unset,
        targetCaldavCalendarUrl: Patch<String> = .unset,
        targetOutlookAccountId: Patch<Int> = .unset,
        targetOutlookCalendarId: Patch<String> = .unset,
        recurrenceRule: Patch<String> = .unset,
        localCalendarId: Int? = nil,
        confirmedOrphanCount: Int? = nil
    ) {
        self.title = title
        self.description = description
        self.startDatetime = startDatetime
        self.endDatetime = endDatetime
        self.allDay = allDay
        self.location = location
        self.color = color
        self.icon = icon
        self.assignedTo = assignedTo
        self.visibility = visibility
        self.countdown = countdown
        self.attachmentName = attachmentName
        self.attachmentData = attachmentData
        self.removeAttachment = removeAttachment
        self.documentFolderName = documentFolderName
        self.documentName = documentName
        self.documentDescription = documentDescription
        self.targetGoogleCalendarId = targetGoogleCalendarId
        self.targetCaldavAccountId = targetCaldavAccountId
        self.targetCaldavCalendarUrl = targetCaldavCalendarUrl
        self.targetOutlookAccountId = targetOutlookAccountId
        self.targetOutlookCalendarId = targetOutlookCalendarId
        self.recurrenceRule = recurrenceRule
        self.localCalendarId = localCalendarId
        self.confirmedOrphanCount = confirmedOrphanCount
    }
}
