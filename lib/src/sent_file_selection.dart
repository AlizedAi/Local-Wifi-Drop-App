/// Removes only the exact selected items included in a completed send batch.
void removeSuccessfullySentFiles<T>(List<T> selected, Iterable<T> sent) {
  final sentByIdentity = Set<T>.identity()..addAll(sent);
  selected.removeWhere(sentByIdentity.contains);
}
