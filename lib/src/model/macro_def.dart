import 'package:equatable/equatable.dart';
import 'package:icicles_animation_dart/icicles_animation_dart.dart';
import 'package:icicles_generators/icicles_generators.dart';

/// What a [MacroDef] holds.
enum MacroKind { number, color }

/// A composition macro: a named global binding ("Intensity", "Color A"…)
/// any generator or effect parameter reads through a `MacroBinding(id)`.
/// The host passes the macros of the composition to every bake
/// (`BakeRequest.macros`), so a macro can be a constant, keyframed on the
/// composition clock, audio-driven, random, stacked…
///
/// A number macro has a [min]..[max] range (its unit range for stacking),
/// a color macro ignores them. [binding] is always valid for [spec]
/// (salvaged at construction); a macro never reads another macro.
///
/// Throws an [ArgumentError] for an empty [id], a name with the NUL
/// character, a non-finite or inverted range, or a default of the wrong
/// type.
class MacroDef extends Equatable {
  final String id;
  final String name;
  final MacroKind kind;

  /// Range of a number macro (`0..1` for a color macro).
  final double min;
  final double max;

  /// A `double` ([MacroKind.number]) or a [Color] ([MacroKind.color]).
  final Object defaultValue;
  final ParamBinding binding;

  MacroDef._({
    required this.id,
    required this.name,
    required this.kind,
    required this.min,
    required this.max,
    required this.defaultValue,
    required ParamBinding? binding,
  }) : binding = _specFor(id, name, kind, min, max, defaultValue).salvage(binding) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty.');
    if (name.contains('\u0000')) {
      throw ArgumentError.value(name, 'name', 'Must not contain the NUL character.');
    }
  }

  /// A number macro; [binding] defaults to a constant of [defaultValue].
  factory MacroDef.number({
    required String id,
    required String name,
    double min = 0,
    double max = 1,
    double defaultValue = 0,
    ParamBinding? binding,
  }) {
    if (!min.isFinite || !max.isFinite || min >= max) {
      throw ArgumentError.value((min, max), 'min/max', 'Must be a finite range with min < max.');
    }
    if (!defaultValue.isFinite) throw ArgumentError.value(defaultValue, 'defaultValue', 'Must be finite.');
    return MacroDef._(
      id: id,
      name: name,
      kind: MacroKind.number,
      min: min,
      max: max,
      defaultValue: defaultValue.clamp(min, max),
      binding: binding,
    );
  }

  /// A color macro; [binding] defaults to a constant of [defaultValue].
  factory MacroDef.color({
    required String id,
    required String name,
    Color defaultValue = const Color(0xFFFFFFFF),
    ParamBinding? binding,
  }) =>
      MacroDef._(
          id: id, name: name, kind: MacroKind.color, min: 0, max: 1, defaultValue: defaultValue, binding: binding);

  /// A macro of [kind] with the kind's default value.
  factory MacroDef({
    required String id,
    required String name,
    required MacroKind kind,
    double min = 0,
    double max = 1,
    Object? defaultValue,
    ParamBinding? binding,
  }) =>
      switch (kind) {
        MacroKind.number => MacroDef.number(
            id: id,
            name: name,
            min: min,
            max: max,
            defaultValue: switch (defaultValue) {
              final num value => value.toDouble(),
              null => min,
              _ => throw ArgumentError.value(defaultValue, 'defaultValue', 'A number macro needs a number.'),
            },
            binding: binding,
          ),
        MacroKind.color => MacroDef.color(
            id: id,
            name: name,
            defaultValue: switch (defaultValue) {
              final Color value => value,
              null => const Color(0xFFFFFFFF),
              _ => throw ArgumentError.value(defaultValue, 'defaultValue', 'A color macro needs a color.'),
            },
            binding: binding,
          ),
      };

  static ParamSpec _specFor(String id, String name, MacroKind kind, double min, double max, Object defaultValue) =>
      switch (kind) {
        MacroKind.number =>
          NumberParam(id: id, label: LocalizedText(name), min: min, max: max, defaultValue: defaultValue as double),
        MacroKind.color => ColorParam(id: id, label: LocalizedText(name), defaultValue: defaultValue as Color),
      };

  /// The parameter schema of this macro: what its [binding] is salvaged
  /// against, and what a host builds the macro's control from.
  ParamSpec get spec => _specFor(id, name, kind, min, max, defaultValue);

  bool get isNumber => kind == MacroKind.number;

  bool get isColor => kind == MacroKind.color;

  /// A copy with the given fields replaced; the binding is re-salvaged
  /// against the new range.
  MacroDef copyWith({String? name, double? min, double? max, Object? defaultValue, ParamBinding? binding}) => MacroDef(
        id: id,
        name: name ?? this.name,
        kind: kind,
        min: min ?? this.min,
        max: max ?? this.max,
        defaultValue: defaultValue ?? this.defaultValue,
        binding: binding ?? this.binding,
      );

  @override
  List<Object?> get props => [id, name, kind, min, max, defaultValue, binding];
}

/// The ids of the macros [binding] reads: a [MacroBinding] itself, and,
/// through a [StackedBinding], its base, the modulator sources and their
/// depth bindings.
Set<String> macroIdsOf(ParamBinding binding) {
  final ids = <String>{};
  void walk(ParamBinding b) {
    switch (b) {
      case MacroBinding(:final macroId):
        ids.add(macroId);
      case StackedBinding(:final base, :final modulators):
        walk(base);
        for (final modulator in modulators) {
          walk(modulator.source);
          if (modulator.depthBinding case final depth?) walk(depth);
        }
      default:
        break;
    }
  }

  walk(binding);
  return ids;
}
