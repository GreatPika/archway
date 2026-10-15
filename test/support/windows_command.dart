// Developer-only explicit Windows process representation, never a shell encoder.
import 'package:path/path.dart' as p;

final class WindowsRawCommandLine {
  WindowsRawCommandLine({
    required this.applicationName,
    required this.commandLine,
    required List<String> logicalArguments,
  }) : logicalArguments = List.unmodifiable(logicalArguments) {
    if (!p.windows.isAbsolute(applicationName) ||
        applicationName.contains('\u0000') ||
        commandLine.isEmpty ||
        commandLine.contains('\u0000') ||
        commandLine.length >= 32767 ||
        logicalArguments.isEmpty ||
        logicalArguments.any((argument) => argument.contains('\u0000'))) {
      throw ArgumentError('Invalid explicit Windows command representation');
    }
  }

  final String applicationName, commandLine;
  final List<String> logicalArguments;

  void validateFor(List<String> arguments) {
    if (arguments.length != logicalArguments.length ||
        List.generate(
          arguments.length,
          (index) => index,
        ).any((index) => arguments[index] != logicalArguments[index])) {
      throw ArgumentError(
        'Windows execution differs from recorded logical argv',
      );
    }
  }

  Map<String, Object> toJson() => {
    'application_name': applicationName,
    'command_line': commandLine,
    'logical_arguments': logicalArguments,
  };
}
