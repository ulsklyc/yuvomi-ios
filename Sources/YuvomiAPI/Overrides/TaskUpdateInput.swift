// Handgeschrieben statt generiert, siehe typeOverrides in openapi-generator-config.yaml.
// Felder wie Components.Schemas.TaskUpdateInput in Spec/openapi.json.

/// Body von `PUT /tasks/{id}`. Was fehlt, bleibt wie gespeichert.
///
/// Felder, die `null` annehmen, sind ein `Patch`; die übrigen werden bei `nil` weggelassen.
/// `assigned_to` und `tags` gehen immer als Liste. Die Spec erlaubt auch eine Zahl oder
/// einen kommagetrennten String, die App braucht beides nicht.
struct TaskUpdateInput: Codable, Hashable, Sendable {
    var title: String? = nil
    var description: Patch<String> = .unset
    var category: String? = nil
    var priority: String? = nil
    var startDate: Patch<String> = .unset
    var dueDate: Patch<String> = .unset
    var dueTime: Patch<String> = .unset
    var assignedTo: Patch<[Int]> = .unset
    var tags: Patch<[String]> = .unset
    var isRecurring: Bool? = nil
    var recurrenceRule: Patch<String> = .unset
    var recurrenceFromCompletion: Bool? = nil
    var points: Patch<Int> = .unset
    var visibility: String? = nil
    var countdown: Bool? = nil
    var locked: Bool? = nil
    var syncTarget: Patch<String> = .unset
    var status: String? = nil

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case category
        case priority
        case startDate = "start_date"
        case dueDate = "due_date"
        case dueTime = "due_time"
        case assignedTo = "assigned_to"
        case tags
        case isRecurring = "is_recurring"
        case recurrenceRule = "recurrence_rule"
        case recurrenceFromCompletion = "recurrence_from_completion"
        case points
        case visibility
        case countdown
        case locked
        case syncTarget = "sync_target"
        case status
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(dueDate, forKey: .dueDate)
        try container.encode(dueTime, forKey: .dueTime)
        try container.encode(assignedTo, forKey: .assignedTo)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(isRecurring, forKey: .isRecurring)
        try container.encode(recurrenceRule, forKey: .recurrenceRule)
        try container.encodeIfPresent(recurrenceFromCompletion, forKey: .recurrenceFromCompletion)
        try container.encode(points, forKey: .points)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        try container.encodeIfPresent(countdown, forKey: .countdown)
        try container.encodeIfPresent(locked, forKey: .locked)
        try container.encode(syncTarget, forKey: .syncTarget)
        try container.encodeIfPresent(status, forKey: .status)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decode(Patch<String>.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        startDate = try container.decode(Patch<String>.self, forKey: .startDate)
        dueDate = try container.decode(Patch<String>.self, forKey: .dueDate)
        dueTime = try container.decode(Patch<String>.self, forKey: .dueTime)
        assignedTo = try container.decode(Patch<[Int]>.self, forKey: .assignedTo)
        tags = try container.decode(Patch<[String]>.self, forKey: .tags)
        isRecurring = try container.decodeIfPresent(Bool.self, forKey: .isRecurring)
        recurrenceRule = try container.decode(Patch<String>.self, forKey: .recurrenceRule)
        recurrenceFromCompletion = try container.decodeIfPresent(Bool.self, forKey: .recurrenceFromCompletion)
        points = try container.decode(Patch<Int>.self, forKey: .points)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        countdown = try container.decodeIfPresent(Bool.self, forKey: .countdown)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked)
        syncTarget = try container.decode(Patch<String>.self, forKey: .syncTarget)
        status = try container.decodeIfPresent(String.self, forKey: .status)
    }
}

extension TaskUpdateInput {
    init(
        title: String? = nil,
        description: Patch<String> = .unset,
        category: String? = nil,
        priority: String? = nil,
        startDate: Patch<String> = .unset,
        dueDate: Patch<String> = .unset,
        dueTime: Patch<String> = .unset,
        assignedTo: Patch<[Int]> = .unset,
        tags: Patch<[String]> = .unset,
        isRecurring: Bool? = nil,
        recurrenceRule: Patch<String> = .unset,
        recurrenceFromCompletion: Bool? = nil,
        points: Patch<Int> = .unset,
        visibility: String? = nil,
        countdown: Bool? = nil,
        locked: Bool? = nil,
        syncTarget: Patch<String> = .unset,
        status: String? = nil
    ) {
        self.title = title
        self.description = description
        self.category = category
        self.priority = priority
        self.startDate = startDate
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.assignedTo = assignedTo
        self.tags = tags
        self.isRecurring = isRecurring
        self.recurrenceRule = recurrenceRule
        self.recurrenceFromCompletion = recurrenceFromCompletion
        self.points = points
        self.visibility = visibility
        self.countdown = countdown
        self.locked = locked
        self.syncTarget = syncTarget
        self.status = status
    }
}
