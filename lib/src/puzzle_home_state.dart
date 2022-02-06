// Copyright 2020, the Flutter project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:ar_flutter_plugin/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin/datatypes/node_types.dart';
import 'package:ar_flutter_plugin/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin/models/ar_anchor.dart';
import 'package:ar_flutter_plugin/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin/models/ar_node.dart';
import 'package:provider/provider.dart';
import 'package:slide_puzzle/src/theme_ar.dart';
import 'package:slide_puzzle/src/value_tab_controller.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'app_state.dart';
import 'core/puzzle_animator.dart';
import 'core/puzzle_proxy.dart';
import 'flutter.dart';
import 'puzzle_controls.dart';
import 'shared_theme.dart';
import 'themes.dart';

class _PuzzleControls extends ChangeNotifier implements PuzzleControls {
  final PuzzleHomeState _parent;

  _PuzzleControls(this._parent);

  @override
  bool get autoPlay => _parent._autoPlay;

  void _notify() => notifyListeners();

  @override
  void Function(bool? newValue)? get setAutoPlayFunction {
    if (_parent.puzzle.solved) {
      return null;
    }
    return _parent._setAutoPlay;
  }

  @override
  int get clickCount => _parent.puzzle.clickCount;

  @override
  int get incorrectTiles => _parent.puzzle.incorrectTiles;

  @override
  void reset() => _parent.puzzle.reset();
}

class PuzzleHomeState extends State
    with SingleTickerProviderStateMixin, AppState {
  @override
  final PuzzleAnimator puzzle;

  @override
  final _AnimationNotifier animationNotifier = _AnimationNotifier();
  bool started = false;

  Duration _tickerTimeSinceLastEvent = Duration.zero;
  late Ticker _ticker;
  late Duration _lastElapsed;
  late StreamSubscription _puzzleEventSubscription;

  bool _autoPlay = false;
  late _PuzzleControls _autoPlayListenable;

  late final ARObjectManager arObjectManager;
  late final ARAnchorManager arAnchorManager;
  late final ARSessionManager arSessionManager;
  late final ARViewCreatedCallback onARViewCreated;

  PuzzleHomeState(this.puzzle) {
    _puzzleEventSubscription = puzzle.onEvent.listen(_onPuzzleEvent);
  }

  void initPuzzle(ARHitTestResult hitTestResult) async {
    // puzzle = puzzle;

    await puzzle.reGenerateNodes(
        hitTestResult.distance, hitTestResult.worldTransform);

    // addNodes(hitTestResult);
    if (!started) {
      _ticker = createTicker(_onTick);
      _lastElapsed = Duration.zero;
      _ensureTicking();
    }
  }

  void addNodes(ARHitTestResult hitTestResult) async {
    final anchor = puzzle.arPlaneAnchors[0];
    // final anchor = ARPlaneAnchor(transformation: hitTestResult.worldTransform);
    var newNode = puzzle.node(0);
    var didAddAnchor = await arAnchorManager.addAnchor(anchor);
    var result = await arObjectManager.addNode(newNode, planeAnchor: anchor);
  }

  void _setAutoPlay(bool? newValue) {
    if (newValue != _autoPlay) {
      setState(() {
        // Only allow enabling autoPlay if the puzzle is not solved
        _autoPlayListenable._notify();
        _autoPlay = newValue! && !puzzle.solved;
        if (_autoPlay) {
          _ensureTicking();
        }
      });
    }
  }

  @override
  void initState() {
    _autoPlayListenable = _PuzzleControls(this);
    super.initState();
    onARViewCreated = arCreate;
  }

  void arCreate(
      ARSessionManager arSessionManager,
      ARObjectManager arObjectManager,
      ARAnchorManager arAnchorManager,
      ARLocationManager arLocationManager) {
    print('creating ar view');
    this.arSessionManager = arSessionManager;
    this.arObjectManager = arObjectManager;
    this.arAnchorManager = arAnchorManager;

    this.arSessionManager.onInitialize(
          showFeaturePoints: false,
          showPlanes: true,
          showWorldOrigin: true,
          handleTaps: true,
          handlePans: true,
          handleRotation: true,
        );
    this.arObjectManager.onInitialize();
    this.arSessionManager.onError('errorMessage');
    this.arSessionManager.onPlaneOrPointTap = onPlaneOrPointTapped;
    // this.arObjectManager.onPanStart = onPanStarted;
    // this.arObjectManager.onPanChange = onPanChanged;
    // this.arObjectManager.onPanEnd = onPanEnded;
    this.arObjectManager.onNodeTap = onNodeTap;
    // this.arObjectManager.onRotationStart = onRotationStarted;
    // this.arObjectManager.onRotationChange = onRotationChanged;
    // this.arObjectManager.onRotationEnd = onRotationEnded;
  }

  void onNodeTap(List<String> nodeNames) {
    for (final nodeName in nodeNames) {
      print('node_$nodeName');
      puzzle.clickOrShake(int.parse(nodeName));
    }
  }

  Future<void> onPlaneOrPointTapped(
      List<ARHitTestResult> hitTestResults) async {
    final singleHitTestResult = hitTestResults.firstWhere(
        (hitTestResult) => hitTestResult.type == ARHitTestResultType.plane);
    initPuzzle(singleHitTestResult);
    if (started) {
      print('started');
    }
  }

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          Provider<AppState>.value(value: this),
          ListenableProvider<PuzzleControls>.value(
            value: _autoPlayListenable,
          )
        ],
        child: const Material(child: LayoutBuilder(builder: _doBuild)),
      );

  @override
  void dispose() {
    animationNotifier.dispose();
    _ticker.dispose();
    _autoPlayListenable.dispose();
    _puzzleEventSubscription.cancel();
    arSessionManager.dispose();
    super.dispose();
  }

  void _onPuzzleEvent(PuzzleEvent e) {
    _autoPlayListenable._notify();
    if (e != PuzzleEvent.random) {
      _setAutoPlay(false);
    }
    _tickerTimeSinceLastEvent = Duration.zero;

    _ensureTicking();
    setState(() {
      // noop
    });
  }

  void _ensureTicking() {
    if (!_ticker.isTicking) {
      _ticker.start();
      setState(() {
        started = true;
      });
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed == Duration.zero) {
      _lastElapsed = elapsed;
    }
    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;

    if (delta.inMilliseconds <= 0) {
      // `_delta` may be negative or zero if `elapsed` is zero (first tick)
      // or during a restart. Just ignore this case.
      return;
    }

    _tickerTimeSinceLastEvent += delta;
    puzzle.update(delta > _maxFrameDuration ? _maxFrameDuration : delta);

    if (!puzzle.stable) {
      animationNotifier.animate();
    } else {
      if (!_autoPlay) {
        _ticker.stop();
        _lastElapsed = Duration.zero;
      }
    }

    if (_autoPlay &&
        _tickerTimeSinceLastEvent > const Duration(milliseconds: 200)) {
      puzzle.playRandom();

      if (puzzle.solved) {
        _setAutoPlay(false);
      }
    }
  }
}

class Vector3 {}

class _AnimationNotifier extends ChangeNotifier {
  void animate() {
    notifyListeners();
  }
}

const _maxFrameDuration = Duration(milliseconds: 34);

Widget _updateConstraints(
    BoxConstraints constraints, Widget Function(bool small) builder) {
  const _smallWidth = 580;

  final constraintWidth =
      constraints.hasBoundedWidth ? constraints.maxWidth : 1000.0;

  final constraintHeight =
      constraints.hasBoundedHeight ? constraints.maxHeight : 1000.0;

  return builder(constraintWidth < _smallWidth || constraintHeight < 690);
}

Widget _doBuild(BuildContext _, BoxConstraints constraints) =>
    _updateConstraints(constraints, _doBuildCore);

Widget _doBuildCore(bool small) => ValueTabController<SharedTheme>(
      values: themes,
      child: Consumer<SharedTheme>(
        builder: (_, theme, __) => AnimatedContainer(
          duration: puzzleAnimationDuration,
          child: Center(
            child: theme.styledWrapper(
              small,
              Stack(
                children: [
                  Consumer<AppState>(
                    builder: (context, appState, _) => ARView(
                      onARViewCreated: appState.onARViewCreated,
                      planeDetectionConfig:
                          PlaneDetectionConfig.horizontalAndVertical,
                    ),
                  ),
                  Consumer<AppState>(builder: (context, appState, _) {
                    return Center(
                      child: Container(
                        height: 30,
                        child: ElevatedButton(
                          child: const Text('start'),
                          onPressed: () {
                            (theme as ThemeAr).addNodes(appState, small);
                          },
                        ),
                      ),
                    );
                    // return Flexible(
                    //   child: Container(
                    //     padding: const EdgeInsets.all(10),
                    //     child: Flow(
                    //       delegate: PuzzleFlowDelegate(
                    //         small ? const Size(90, 90) : const Size(140, 140),
                    //         appState.puzzle,
                    //         appState.animationNotifier,
                    //       ),
                    //       children: List<Widget>.generate(
                    //         appState.puzzle.length,
                    //         (i) =>
                    //             theme.tileButtonCore(i, appState.puzzle, small),
                    //       ),
                    //     ),
                    //   ),
                    // );
                  }),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 50,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        border: Border(
                          top: BorderSide(color: Colors.black26, width: 1),
                        ),
                      ),
                      padding: const EdgeInsets.only(
                        left: 10,
                        bottom: 6,
                        top: 2,
                        right: 10,
                      ),
                      child: Consumer<PuzzleControls>(
                        builder: (_, controls, __) =>
                            Row(children: theme.bottomControls(controls)),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );

// SizedBox(
//   width: 580,
//   child: Consumer<AppState>(
//     builder: (context, appState, _) => Column(
//       mainAxisSize: MainAxisSize.min,
//       crossAxisAlignment: CrossAxisAlignment.center,
//       children: <Widget>[
//         Container(
//           decoration: const BoxDecoration(
//             border: Border(
//               bottom: BorderSide(
//                 color: Colors.black26,
//                 width: 1,
//               ),
//             ),
//           ),
//           margin: const EdgeInsets.symmetric(horizontal: 20),
//           child: TabBar(
//             controller: ValueTabController.of(context),
//             labelPadding: const EdgeInsets.fromLTRB(0, 20, 0, 12),
//             labelColor: theme.puzzleAccentColor,
//             indicatorColor: theme.puzzleAccentColor,
//             indicatorWeight: 1.5,
//             unselectedLabelColor: Colors.black.withOpacity(0.6),
//             tabs: themes
//                 .map((st) => Text(
//                       st.name.toUpperCase(),
//                       style: const TextStyle(
//                         letterSpacing: 0.5,
//                       ),
//                     ))
//                 .toList(),
//           ),
//         ),
//         Flexible(
//           child: Container(
//             padding: const EdgeInsets.all(10),
//             child: Flow(
//               delegate: PuzzleFlowDelegate(
//                 small ? const Size(90, 90) : const Size(140, 140),
//                 appState.puzzle,
//                 appState.animationNotifier,
//               ),
//               children: List<Widget>.generate(
//                 appState.puzzle.length,
//                 (i) => theme.tileButtonCore(
//                     i, appState.puzzle, small),
//               ),
//             ),
//           ),
//         ),
// Container(
//   decoration: const BoxDecoration(
//     border: Border(
//       top: BorderSide(color: Colors.black26, width: 1),
//     ),
//   ),
//   padding: const EdgeInsets.only(
//     left: 10,
//     bottom: 6,
//     top: 2,
//     right: 10,
//   ),
//   child: Consumer<PuzzleControls>(
//     builder: (_, controls, __) =>
//         Row(children: theme.bottomControls(controls)),
//   ),
// )
//                 ],
//               ),
//             ),
//           ),
//         ),
//       ),
//     ),
//   ),
// );

