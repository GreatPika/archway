/// The canonical selected root and its lexical root-relative policy path.
class RepositorySelection {
  final String root;
  final String policyPath;
  const RepositorySelection(this.root, [this.policyPath = 'architecture.yaml']);
}

class PolicyDiagnostic {
  final String code;
  final String severity;
  final String message;
  final String? rulePointer;
  final String? path;
  const PolicyDiagnostic(
    this.code,
    this.severity,
    this.message, [
    this.rulePointer,
    this.path,
  ]);
}

class Ownership {
  final String path;
  final String ownership;
  final String? ownerId;
  const Ownership(this.path, this.ownership, this.ownerId);
  Map<String, Object?> toJson() => {
    'path': path,
    'ownership': ownership,
    'owner_id': ownerId,
  };
}

class PlanNode {
  final String id;
  final String responsibility;
  final List<String> owns;
  final List<String> public;
  final List<String> allows;
  final List<String> contracts;
  final int policyIndex;
  PlanNode(
    this.id,
    this.responsibility,
    List<String> owns,
    List<String> public,
    List<String> allows,
    List<String> contracts,
    this.policyIndex,
  ) : owns = List.unmodifiable(owns),
      public = List.unmodifiable(public),
      allows = List.unmodifiable(allows),
      contracts = List.unmodifiable(contracts);
}

class PlanProject {
  final String id;
  final String adapter;
  final List<String> packageRoots;
  final int policyIndex;
  PlanProject(
    this.id,
    this.adapter,
    List<String> packageRoots,
    this.policyIndex,
  ) : packageRoots = List.unmodifiable(packageRoots);
}

class PolicyDecision {
  final String decision;
  final String reason;
  const PolicyDecision(this.decision, this.reason);
}
