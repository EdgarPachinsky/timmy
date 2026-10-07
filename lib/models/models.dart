import 'package:flutter/painting.dart';

/// Parses "#rrggbb" into a [Color], falling back to grey for anything else.
Color colorFromHex(String? hex) {
  final value = hex?.replaceFirst('#', '');
  if (value == null || value.length != 6) return const Color(0xFF94A3B8);
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? const Color(0xFF94A3B8) : Color(0xFF000000 | parsed);
}

class User {
  const User({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
  });

  final int id;
  final String email;
  final String name;
  final String role;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as int,
        email: json['email'] as String,
        name: json['name'] as String? ?? json['email'] as String,
        role: json['role'] as String? ?? 'user',
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'email': email, 'name': name, 'role': role};

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }
}

class Workspace {
  const Workspace({
    required this.id,
    required this.name,
    this.description,
    required this.timezone,
    required this.memberCount,
    required this.projectCount,
    required this.myRole,
  });

  final int id;
  final String name;
  final String? description;
  final String timezone;
  final int memberCount;
  final int projectCount;
  final String myRole;

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        id: json['id'] as int,
        name: json['name'] as String,
        description: json['description'] as String?,
        timezone: json['timezone'] as String? ?? 'UTC',
        memberCount: json['memberCount'] as int? ?? 0,
        projectCount: json['projectCount'] as int? ?? 0,
        myRole: json['myRole'] as String? ?? 'member',
      );
}

class Client {
  const Client({
    required this.id,
    required this.firstName,
    required this.lastName,
    this.description,
  });

  final int id;
  final String firstName;
  final String lastName;
  final String? description;

  String get fullName => '$firstName $lastName'.trim();

  factory Client.fromJson(Map<String, dynamic> json) => Client(
        id: json['id'] as int,
        firstName: json['firstName'] as String? ?? '',
        lastName: json['lastName'] as String? ?? '',
        description: json['description'] as String?,
      );
}

class Project {
  const Project({
    required this.id,
    required this.name,
    this.description,
    required this.color,
    required this.status,
    this.client,
    this.memberCount = 0,
    this.totalMinutes = 0,
  });

  final int id;
  final String name;
  final String? description;
  final Color color;
  final String status;
  final Client? client;
  final int memberCount;
  final int totalMinutes;

  bool get isActive => status == 'active';

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as int,
        name: json['name'] as String,
        description: json['description'] as String?,
        color: colorFromHex(json['color'] as String?),
        status: json['status'] as String? ?? 'active',
        client: json['client'] == null
            ? null
            : Client.fromJson(json['client'] as Map<String, dynamic>),
        memberCount: json['memberCount'] as int? ?? 0,
        totalMinutes: json['totalMinutes'] as int? ?? 0,
      );
}

class Tag {
  const Tag({required this.id, required this.name, required this.color});

  final int id;
  final String name;
  final Color color;

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
        id: json['id'] as int,
        name: json['name'] as String,
        color: colorFromHex(json['color'] as String?),
      );
}

class TimeEntry {
  const TimeEntry({
    required this.id,
    required this.projectId,
    required this.project,
    required this.taskTitle,
    this.description,
    required this.totalMinutes,
    required this.date,
    required this.billable,
    required this.tags,
    required this.createdAt,
  });

  final int id;
  final int projectId;
  final Project? project;
  final String taskTitle;
  final String? description;
  final int totalMinutes;

  /// Calendar day the time is booked to, as `yyyy-MM-dd`.
  final String date;
  final bool billable;
  final List<Tag> tags;
  final DateTime? createdAt;

  factory TimeEntry.fromJson(Map<String, dynamic> json) {
    final hours = json['hours'] as int? ?? 0;
    final minutes = json['minutes'] as int? ?? 0;
    return TimeEntry(
      id: json['id'] as int,
      projectId: json['projectId'] as int,
      project: json['project'] == null
          ? null
          : Project.fromJson(json['project'] as Map<String, dynamic>),
      taskTitle: json['taskTitle'] as String? ?? '',
      description: json['description'] as String?,
      totalMinutes: json['totalMinutes'] as int? ?? hours * 60 + minutes,
      date: json['date'] as String,
      billable: json['billable'] as bool? ?? false,
      tags: [
        for (final t in (json['tags'] as List<dynamic>? ?? const []))
          Tag.fromJson(t as Map<String, dynamic>),
      ],
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}
