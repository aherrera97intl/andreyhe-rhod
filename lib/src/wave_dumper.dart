/// Copyright (C) 2021-2023 Intel Corporation
/// SPDX-License-Identifier: BSD-3-Clause
///
/// wave_dumper.dart
/// Waveform dumper for a given module hierarchy, dumps to .vcd file
///
/// 2021 May 7
/// Author: Max Korbel <max.korbel@intel.com>
///

import 'dart:io';
import 'package:rohd/rohd.dart';
import 'package:rohd/src/utilities/config.dart';
import 'package:rohd/src/utilities/sanitizer.dart';
import 'package:rohd/src/utilities/uniquifier.dart';

/// A waveform dumper for simulations.
///
/// Outputs to vcd format at [outputPath].  [module] must be built prior to
/// attaching the [WaveDumper].
///
/// The waves will only dump to the file periodically and then once the
/// simulation has completed.
class WaveDumper {
  /// The [Module] being dumped.
  final Module module;

  /// The output filepath of the generated waveforms.
  final String outputPath;

  /// The file to write dumped output waveform to.
  final File _outputFile;

  /// A sink to write contents into [_outputFile].
  late final IOSink _outFileSink;

  /// A buffer for contents before writing to the file sink.
  final StringBuffer _fileBuffer = StringBuffer();

  /// A counter for tracking signal names in the VCD file.
  int _signalMarkerIdx = 0;

  /// Stores the mapping from [Logic] to signal marker in the VCD file.
  final Map<Logic, String> _signalToMarkerMap = {};

  /// A set of all [Logic]s that have changed in this timestamp so far.
  ///
  /// This spans across multiple inject or changed events if they are in the
  /// same timestamp of the [Simulator].
  final Set<Logic> _changedLogicsThisTimestamp = <Logic>{};

  /// The timestamp which is currently being collected for a dump.
  ///
  /// When the [Simulator] time progresses beyond this, it will dump all the
  /// signals that have changed up until that point at this saved time value.
  var _currentDumpingTimestamp = Simulator.time;

  /// Attaches a [WaveDumper] to record all signal changes in a simulation of
  /// [module] in a VCD file at [outputPath].
  WaveDumper(this.module, {this.outputPath = 'waves.vcd'})
      : _outputFile = File(outputPath) {
    if (!module.hasBuilt) {
      throw Exception(
          'Module must be built before passed to dumper.  Call build() first.');
    }

    _outFileSink = _outputFile.openWrite();

    _collectAllSignals();

    _writeHeader();
    _writeScope();

    Simulator.preTick.listen((args) {
      if (Simulator.time != _currentDumpingTimestamp) {
        if (_changedLogicsThisTimestamp.isNotEmpty) {
          // no need to write blank timestamps
          _captureTimestamp(_currentDumpingTimestamp);
        }
        _currentDumpingTimestamp = Simulator.time;
      }
    });

    Simulator.registerEndOfSimulationAction(() async {
      _captureTimestamp(Simulator.time);

      await _terminate();
    });
  }

  /// Number of characters in the buffer after which it will
  /// write contents to the output file.
  static const _fileBufferLimit = 100000;

  /// Buffers [contents] to be written to the output file.
  void _writeToBuffer(String contents) {
    _fileBuffer.write(contents);

    if (_fileBuffer.length > _fileBufferLimit) {
      _writeToFile();
    }
  }

  /// Writes all pending items in the [_fileBuffer] to the file.
  void _writeToFile() {
    _outFileSink.write(_fileBuffer.toString());
    _fileBuffer.clear();
  }

  /// Terminates the waveform dumping, including closing the file.
  Future<void> _terminate() async {
    _writeToFile();
    await _outFileSink.flush();
    await _outFileSink.close();
  }

  /// Registers all signal value changes to write updates to the dumped VCD.
  void _collectAllSignals() {
    final modulesToParse = <Module>[module];
    for (var i = 0; i < modulesToParse.length; i++) {
      final m = modulesToParse[i];
      for (final sig in m.signals) {
        if (sig is Const) {
          // constant values are "boring" to inspect
          continue;
        }

        _signalToMarkerMap[sig] = 's${_signalMarkerIdx++}';
        sig.changed.listen((args) {
          _changedLogicsThisTimestamp.add(sig);
        });
      }
      for (final subm in m.subModules) {
        if (subm is InlineSystemVerilog) {
          // the InlineSystemVerilog modules are "boring" to inspect
          continue;
        }
        modulesToParse.add(subm);
      }
    }
  }

  /// Writes the top header for the VCD file.
  void _writeHeader() {
    final dateString = DateTime.now().toIso8601String();
    const timescale = '1ps';
    final header = '''
\$date
  $dateString
\$end
\$version
  ROHD v${Config.version}
\$end
\$comment
  Generated by ROHD - www.github.com/intel/rohd
\$end
\$timescale $timescale \$end
''';
    _writeToBuffer(header);
  }

  /// Writes the scope of the VCD, including signal and hierarchy declarations,
  /// as well as initial values.
  void _writeScope() {
    var scopeString = _computeScopeString(module);
    scopeString += '\$enddefinitions \$end\n';
    scopeString += '\$dumpvars\n';
    _writeToBuffer(scopeString);
    _signalToMarkerMap.keys.forEach(_writeSignalValueUpdate);
    _writeToBuffer('\$end\n');
  }

  /// Generates the top of the scope string (signal and hierarchy definitions).
  String _computeScopeString(Module m, {int indent = 0}) {
    final moduleSignalUniquifier = Uniquifier();
    final padding = List.filled(indent, '  ').join();
    var scopeString = '$padding\$scope module ${m.uniqueInstanceName} \$end\n';
    final innerScopeString = StringBuffer();
    for (final sig in m.signals) {
      if (!_signalToMarkerMap.containsKey(sig)) {
        continue;
      }

      final width = sig.width;
      final marker = _signalToMarkerMap[sig];
      var signalName = Sanitizer.sanitizeSV(sig.name);
      signalName = moduleSignalUniquifier.getUniqueName(
          initialName: signalName, reserved: sig.isPort);
      innerScopeString
          .write('  $padding\$var wire $width $marker $signalName \$end\n');
    }
    for (final subModule in m.subModules) {
      innerScopeString
          .write(_computeScopeString(subModule, indent: indent + 1));
    }
    if (innerScopeString.isEmpty) {
      // no need to dump empty scopes
      return '';
    }
    scopeString += innerScopeString.toString();
    scopeString += '$padding\$upscope \$end\n';
    return scopeString;
  }

  /// Writes the current timestamp to the VCD.
  void _captureTimestamp(int timestamp) {
    final timestampString = '#$timestamp\n';
    _writeToBuffer(timestampString);

    _changedLogicsThisTimestamp
      ..forEach(_writeSignalValueUpdate)
      ..clear();
  }

  /// Writes the current value of [signal] to the VCD.
  void _writeSignalValueUpdate(Logic signal) {
    final binaryValue = signal.value.reversed
        .toList()
        .map((e) => e.toString(includeWidth: false))
        .join();
    final updateValue = signal.width > 1
        ? 'b$binaryValue '
        : signal.value.toString(includeWidth: false);
    final marker = _signalToMarkerMap[signal];
    final updateString = '$updateValue$marker\n';
    _writeToBuffer(updateString);
  }
}

/// Deprecated: use [WaveDumper] instead.
@Deprecated('Use WaveDumper instead')
typedef Dumper = WaveDumper;
