"""ADR-016:故事脊椎与节拍——求值器纯函数、剧本装载、plot_state 存取、service 闭环。

求值器必须可复现(验收判据 2):同一 (剧本, 状态, 事实) 序列产出同一状态。
所有副作用都带确定性 id,重放幂等(验收判据 6)。
"""

import asyncio
import json
import tempfile
import time
import unittest
from pathlib import Path

from spring_haven_core.beats import (
    BEAT_TERM_PREFIX,
    BeatConfigurationError,
    BeatDefinition,
    BeatLibrary,
    ChoiceSpec,
    OutcomeSpec,
    PlotDefinition,
    WorldFacts,
    advance_plot_state,
    evaluate_condition,
    plot_finished,
    resolve_plot_choice,
)
from spring_haven_core.memory import HeartloomStore
from spring_haven_core.roles import RoleDefinition, RoleRegistry
from spring_haven_core.service import CompanionService, RequestValidationError

ROLE_IDS = ("ling", "nai")
SAVE = "save-a"
DAY = 86_400


def _beat(
    beat_id: str,
    *,
    role: str = "ling",
    enter: dict | None = None,
    exit_when: dict | None = None,
    ttl: float | None = None,
    outcome: OutcomeSpec | None = None,
    expire_outcome: OutcomeSpec | None = None,
    choices: tuple[ChoiceSpec, ...] = (),
    timeout: ChoiceSpec | None = None,
) -> BeatDefinition:
    return BeatDefinition(
        beat_id=beat_id,
        role=role,
        title=beat_id,
        goal="测试动机",
        enter_when=enter or {"world_day": {"gte": 0}},
        exit_when=exit_when,
        ttl_world_days=ttl,
        outcome=outcome or OutcomeSpec(),
        expire_outcome=expire_outcome,
        choices=tuple(choices),
        timeout_choice=timeout,
    )


def _plot(plot_id: str, beats: tuple[BeatDefinition, ...]) -> PlotDefinition:
    return PlotDefinition(plot_id=plot_id, title="测试剧本", beats=beats)


def _facts(
    day: float,
    *,
    stats: dict | None = None,
    events: tuple = (),
    terms: dict | None = None,
    exited: tuple = (),
) -> WorldFacts:
    return WorldFacts(
        world_day=day,
        stats=stats or {},
        life_events=tuple(events),
        memory_terms=terms or {},
        exited_beats=frozenset(exited),
    )


class ConditionEvaluationTests(unittest.TestCase):
    def test_world_day_bounds(self) -> None:
        facts = _facts(12.0)
        self.assertTrue(evaluate_condition({"world_day": {"gte": 12}}, facts))
        self.assertFalse(evaluate_condition({"world_day": {"gte": 13}}, facts))
        self.assertTrue(evaluate_condition({"world_day": {"gt": 11, "lt": 13}}, facts))
        self.assertFalse(evaluate_condition({"world_day": {"lt": 12}}, facts))

    def test_stat_missing_is_false_not_error(self) -> None:
        facts = _facts(1.0, stats={"ling": {"stress": 55.0}})
        self.assertTrue(
            evaluate_condition({"stat": {"role": "ling", "key": "stress", "gte": 50}}, facts)
        )
        self.assertFalse(
            evaluate_condition({"stat": {"role": "ling", "key": "stress", "gte": 60}}, facts)
        )
        # 客户端没同步过的属性:不成立,而不是炸
        self.assertFalse(
            evaluate_condition({"stat": {"role": "ling", "key": "intimacy", "gte": 0}}, facts)
        )

    def test_life_event_window_and_count(self) -> None:
        events = (
            {"role_id": "nai", "action": "quiet_time", "world_occurred_at": 9.0},
            {"role_id": "nai", "action": "quiet_time", "world_occurred_at": 10.2},
            {"role_id": "ling", "action": "quiet_time", "world_occurred_at": 10.0},
        )
        facts = _facts(11.0, events=events)
        self.assertTrue(
            evaluate_condition(
                {"life_event": {"role": "nai", "action": "quiet_time",
                                 "within_world_days": 2, "count_gte": 1}},
                facts,
            )
        )
        self.assertTrue(
            evaluate_condition(
                {"life_event": {"role": "nai", "action": "quiet_time",
                                 "within_world_days": 2, "count_gte": 2}},
                facts,
            )
        )
        self.assertFalse(
            evaluate_condition(
                {"life_event": {"role": "nai", "action": "quiet_time",
                                 "within_world_days": 1, "count_gte": 2}},
                facts,
            )
        )
        self.assertFalse(
            evaluate_condition(
                {"life_event": {"role": "nai", "action": "dance_practice",
                                 "within_world_days": 5}},
                facts,
            )
        )

    def test_memory_term_is_role_scoped(self) -> None:
        facts = _facts(1.0, terms={"ling": frozenset({"beat:p1/b1"})})
        self.assertTrue(
            evaluate_condition({"memory_term": {"role": "ling", "term": "beat:p1/b1"}}, facts)
        )
        self.assertFalse(
            evaluate_condition({"memory_term": {"role": "nai", "term": "beat:p1/b1"}}, facts)
        )

    def test_combinators(self) -> None:
        facts = _facts(5.0, exited=("b1",))
        self.assertTrue(
            evaluate_condition(
                {"all": [{"world_day": {"gte": 5}}, {"beat_exited": {"beat": "b1"}}]}, facts
            )
        )
        self.assertTrue(
            evaluate_condition(
                {"any": [{"world_day": {"gte": 99}}, {"beat_exited": {"beat": "b1"}}]}, facts
            )
        )
        self.assertTrue(evaluate_condition({"not": {"world_day": {"gte": 99}}}, facts))

    def test_unknown_operator_raises(self) -> None:
        with self.assertRaises(BeatConfigurationError):
            evaluate_condition({"vibes": {"good": True}}, _facts(1.0))
        with self.assertRaises(BeatConfigurationError):
            evaluate_condition({}, _facts(1.0))


class AdvanceStateTests(unittest.TestCase):
    LINEAR = _plot(
        "p1",
        (
            _beat("b1", enter={"world_day": {"gte": 1}}, exit_when={"world_day": {"gte": 3}}),
            _beat("b2", role="nai", enter={"world_day": {"gte": 3}},
                  exit_when={"world_day": {"gte": 5}}),
        ),
    )

    def test_gated_until_first_enter(self) -> None:
        state, transitions = advance_plot_state(self.LINEAR, {}, _facts(0.5))
        self.assertEqual(transitions, [])
        self.assertEqual(state["current_beat_id"], "")

    def test_enter_then_exit_and_enter_next_same_tick(self) -> None:
        state, transitions = advance_plot_state(self.LINEAR, {}, _facts(1.0))
        self.assertEqual([t.kind for t in transitions], ["enter"])
        state, transitions = advance_plot_state(self.LINEAR, state, _facts(3.5))
        self.assertEqual([(t.kind, t.beat_id) for t in transitions],
                         [("exit", "b1"), ("enter", "b2")])
        self.assertEqual(state["current_beat_id"], "b2")
        self.assertEqual(state["history"][0]["resolution"], "completed")

    def test_ttl_expiry(self) -> None:
        plot = _plot("p1", (_beat("b1", enter={"world_day": {"gte": 1}}, ttl=2.0),))
        state, _ = advance_plot_state(plot, {}, _facts(1.0))
        state, transitions = advance_plot_state(plot, state, _facts(3.5))
        self.assertEqual(transitions[0].resolution, "expired")
        self.assertEqual(state["current_beat_id"], "")

    def test_idle_gap_between_beats(self) -> None:
        plot = _plot(
            "p1",
            (
                _beat("b1", exit_when={"world_day": {"gte": 2}}),
                _beat("b2", enter={"world_day": {"gte": 10}}),
            ),
        )
        state, transitions = advance_plot_state(plot, {}, _facts(0.5))  # b1 进入
        self.assertEqual([t.beat_id for t in transitions], ["b1"])
        state, transitions = advance_plot_state(plot, state, _facts(2.5))  # b1 退出,进入空档
        self.assertEqual([(t.kind, t.beat_id) for t in transitions], [("exit", "b1")])
        self.assertEqual(state["current_beat_id"], "")
        state, transitions = advance_plot_state(plot, state, _facts(9.0))
        self.assertEqual(transitions, [])  # 下一拍还没到:挂着,不许跳
        state, transitions = advance_plot_state(plot, state, _facts(10.0))
        self.assertEqual([t.beat_id for t in transitions], ["b2"])

    def test_pivot_times_out_to_alone(self) -> None:
        plot = _plot(
            "p1",
            (
                _beat(
                    "pivot",
                    enter={"world_day": {"gte": 10}},
                    ttl=2.0,
                    choices=(
                        ChoiceSpec("stay", "陪她", OutcomeSpec()),
                        ChoiceSpec("milk", "不戳穿", OutcomeSpec()),
                    ),
                    timeout=ChoiceSpec("alone", "她自己熬过去", OutcomeSpec()),
                ),
            ),
        )
        state, _ = advance_plot_state(plot, {}, _facts(10.0))
        self.assertEqual(state["current_beat_id"], "pivot")
        state, transitions = advance_plot_state(plot, state, _facts(12.0))
        self.assertEqual(transitions[0].resolution, "alone")
        self.assertEqual(state["current_beat_id"], "")

    def test_resolve_choice(self) -> None:
        plot = _plot(
            "p1",
            (
                _beat(
                    "pivot",
                    ttl=99.0,
                    choices=(ChoiceSpec("stay", "陪她", OutcomeSpec()),),
                    timeout=ChoiceSpec("alone", " alone", OutcomeSpec()),
                ),
            ),
        )
        state, _ = advance_plot_state(plot, {}, _facts(1.0))
        facts = _facts(2.0)
        state, transition = resolve_plot_choice(plot, state, "stay", facts)
        self.assertEqual(transition.resolution, "stay")
        self.assertEqual(state["history"][0]["resolution"], "stay")
        with self.assertRaises(BeatConfigurationError):
            resolve_plot_choice(plot, state, "stay", facts)  # 已经不在枢轴上了
        with self.assertRaises(BeatConfigurationError):
            resolve_plot_choice(plot, state, "nope", _facts(2.0))

    def test_finished_plot_is_quiescent(self) -> None:
        state, transitions = advance_plot_state(self.LINEAR, {}, _facts(1.0))
        state, _ = advance_plot_state(self.LINEAR, state, _facts(3.5))
        state, _ = advance_plot_state(self.LINEAR, state, _facts(5.5))
        self.assertEqual(state["current_beat_id"], "")
        self.assertTrue(plot_finished(state, self.LINEAR))
        state, transitions = advance_plot_state(self.LINEAR, state, _facts(99.0))
        self.assertEqual(transitions, [])
        self.assertTrue(plot_finished(state, self.LINEAR))

    def test_reproducible(self) -> None:
        """验收判据 2:同一输入两次求值,状态逐字节一致。"""
        state_a, t_a = advance_plot_state(self.LINEAR, {}, _facts(1.0))
        state_b, t_b = advance_plot_state(self.LINEAR, {}, _facts(1.0))
        self.assertEqual(state_a, state_b)
        self.assertEqual(t_a, t_b)

    def test_unknown_current_beat_is_released(self) -> None:
        """剧本内容更新后旧存档挂着已删除的节拍:释放而不是卡死。"""
        state = {
            "current_beat_id": "ghost",
            "entered_world_day": 1.0,
            "started_world_day": 1.0,
            "history": [],
        }
        state, transitions = advance_plot_state(self.LINEAR, state, _facts(2.0))
        self.assertEqual(transitions[0].beat_id, "ghost")
        self.assertEqual(state["history"][0]["beat_id"], "ghost")


class PlotLoadingTests(unittest.TestCase):
    def test_loads_shipped_first_thunder(self) -> None:
        root = Path(__file__).resolve().parents[1] / "config" / "beats"
        library = BeatLibrary.load_dir(root, ROLE_IDS)
        plot = library.get("first-thunder")
        self.assertEqual([b.beat_id for b in plot.beats],
                         ["forecast", "noticed", "scheduled", "storm-night", "after-rain"])
        pivot = plot.beat("storm-night")
        assert pivot is not None
        self.assertTrue(pivot.is_pivot)
        self.assertEqual(
            [c.choice_id for c in pivot.choices], ["stay", "milk"]
        )
        assert pivot.timeout_choice is not None
        self.assertEqual(pivot.timeout_choice.choice_id, "alone")

    def test_missing_dir_is_empty_library(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            library = BeatLibrary.load_dir(Path(tmp) / "nope", ROLE_IDS)
        self.assertEqual(library.plots(), [])

    def test_bad_content_fails_loud(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cases = [
                # 未知角色
                {"plot_id": "p", "title": "t", "beats": [{"id": "b", "role": "ghost",
                                                          "title": "t", "goal": "g"}]},
                # 无退出手段
                {"plot_id": "p", "title": "t", "beats": [{"id": "b", "role": "ling",
                                                          "title": "t", "goal": "g"}]},
                # 枢轴带 exit_when
                {"plot_id": "p", "title": "t", "beats": [
                    {"id": "b", "role": "ling", "title": "t", "goal": "g",
                     "exit_when": {"world_day": {"gte": 1}},
                     "choices": [{"id": "a", "label": "A"}],
                     "timeout_choice": {"id": "z", "label": "Z"}}]},
                # 未知条件算子
                {"plot_id": "p", "title": "t", "beats": [
                    {"id": "b", "role": "ling", "title": "t", "goal": "g",
                     "enter_when": {"vibes": {"good": True}},
                     "exit_when": {"world_day": {"gte": 1}}}]},
                # 重复节拍 id
                {"plot_id": "p", "title": "t", "beats": [
                    {"id": "b", "role": "ling", "title": "t", "goal": "g",
                     "exit_when": {"world_day": {"gte": 1}}},
                    {"id": "b", "role": "ling", "title": "t", "goal": "g",
                     "exit_when": {"world_day": {"gte": 2}}}]},
            ]
            for index, payload in enumerate(cases):
                path = root / f"bad{index}.json"
                path.write_text(
                    json.dumps({"plots": [payload]}, ensure_ascii=False), encoding="utf-8"
                )
                with self.assertRaises(BeatConfigurationError, msg=f"case {index}"):
                    BeatLibrary.load_dir(root, ROLE_IDS)


class PlotStateStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "heartloom.sqlite3", ROLE_IDS)

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def test_plot_state_roundtrip(self) -> None:
        self.assertIsNone(self.store.get_plot_state(SAVE, "p1"))
        self.store.save_plot_state(
            save_id=SAVE,
            plot_id="p1",
            spine=["b1", "b2"],
            current_beat_id="b2",
            entered_world_day=3.5,
            started_world_day=1.0,
            history=[{"beat_id": "b1", "entered_world_day": 1.0,
                      "exited_world_day": 3.0, "resolution": "completed"}],
        )
        state = self.store.get_plot_state(SAVE, "p1")
        assert state is not None
        self.assertEqual(state["current_beat_id"], "b2")
        self.assertEqual(state["spine"], ["b1", "b2"])
        self.assertEqual(state["history"][0]["resolution"], "completed")
        self.assertEqual(len(self.store.list_plot_states(SAVE)), 1)
        # 覆盖写(整行 upsert)
        self.store.save_plot_state(
            save_id=SAVE, plot_id="p1", spine=["b1", "b2"], current_beat_id="",
            entered_world_day=0.0, started_world_day=1.0,
            history=[{"beat_id": "b1", "entered_world_day": 1.0,
                      "exited_world_day": 3.0, "resolution": "completed"},
                     {"beat_id": "b2", "entered_world_day": 3.5,
                      "exited_world_day": 5.0, "resolution": "completed"}],
        )
        state = self.store.get_plot_state(SAVE, "p1")
        assert state is not None
        self.assertEqual(len(state["history"]), 2)

    def test_beat_memory_terms_respect_scope(self) -> None:
        self.assertEqual(self.store.beat_memory_terms(SAVE, "ling"), set())
        self.store.put_memory(
            {
                "save_id": SAVE,
                "scope_role_id": "ling",
                "kind": "episodic",
                "title": "心事",
                "content": "测试内容",
                "trigger_terms": [f"{BEAT_TERM_PREFIX}p1/b1"],
                "source_event_id": "p1:b1:completed",
            },
            source="plot",
        )
        self.assertEqual(self.store.beat_memory_terms(SAVE, "ling"), {f"{BEAT_TERM_PREFIX}p1/b1"})
        self.assertEqual(self.store.beat_memory_terms(SAVE, "nai"), set())

    def test_life_save_ids_and_event_row_world_time(self) -> None:
        self.assertEqual(self.store.life_save_ids(), [])
        now = int(time.time())
        self.store.sync_life_state(
            save_id=SAVE,
            selected_role_id="ling",
            snapshot={"roles": {"ling": {"stats": {"stress": 40.0}}}},
            last_user_activity_at=now,
            next_event_at=now,
            now=now,
        )
        self.assertEqual(self.store.life_save_ids(), [SAVE])
        self.store.record_life_events(
            save_id=SAVE,
            events=[{"event_id": "e1", "role_id": "ling", "action": "plot",
                     "description": "d", "occurred_at_unix": now}],
        )
        row = self.store.list_life_events(save_id=SAVE)[0]
        self.assertIn("world_occurred_at", row)
        self.assertGreaterEqual(row["world_occurred_at"], 0.0)


class _StubProvider:
    """节拍求值路径不触碰 LLM;占位即可。"""


class ServiceLoopTests(unittest.TestCase):
    """service 闭环:求值 → 落事件/记忆 → 状态推进 → 枢轴选择。"""

    PLOT = _plot(
        "p1",
        (
            _beat("b1", enter={"world_day": {"gte": 1}},
                  exit_when={"world_day": {"gte": 2}},
                  outcome=OutcomeSpec(memory={"title": "一", "content": "第一拍的记忆",
                                              "importance": 0.5, "valence": 0.1})),
            _beat("b2", role="nai", enter={"world_day": {"gte": 2}},
                  exit_when={"world_day": {"gte": 4}}),
            _beat(
                "pivot",
                enter={"world_day": {"gte": 5}},
                ttl=2.0,
                choices=(
                    ChoiceSpec("stay", "陪她",
                               OutcomeSpec(memory={"title": "选择", "content": "她选了陪伴"},
                                           mood={"p": 0.2})),
                    ChoiceSpec("milk", "不戳穿",
                               OutcomeSpec(memory={"title": "选择", "content": "她选了 discretion"})),
                ),
                timeout=ChoiceSpec("alone", "缺席", OutcomeSpec()),
            ),
        ),
    )

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.store = HeartloomStore(Path(self._tmp.name) / "heartloom.sqlite3", ROLE_IDS)
        registry = RoleRegistry(
            {
                "ling": RoleDefinition(role_id="ling", display_name="小玲",
                                       full_name="春日铃音", aliases=(),
                                       persona_prompt="测试人格"),
                "nai": RoleDefinition(role_id="nai", display_name="小奈",
                                      full_name="白濑雪奈", aliases=(),
                                      persona_prompt="测试人格"),
            },
            None,
        )
        self.service = CompanionService(
            registry, _StubProvider(), self.store,
            beats=BeatLibrary({"p1": self.PLOT}),
        )
        now = int(time.time())
        self.store.set_journey_rate(SAVE, 1.0)  # 重锚:世界日 ≈ (now - t0)/86400
        self.t0 = now
        self.store.sync_life_state(
            save_id=SAVE,
            selected_role_id="ling",
            snapshot={"roles": {"ling": {"stats": {"stress": 40.0}},
                                 "nai": {"stats": {"stress": 20.0}}}},
            last_user_activity_at=now,
            next_event_at=now,
            now=now,
        )

    def tearDown(self) -> None:
        self.service.close()
        self._tmp.cleanup()

    def _at(self, day: float) -> int:
        return self.t0 + int(day * DAY)

    def _tick(self, day: float) -> dict:
        return asyncio.run(self.service.run_due_beats(now=self._at(day)))

    def test_full_spine_with_choice(self) -> None:
        # 第 1 天:进入 b1
        result = self._tick(1.5)
        self.assertGreaterEqual(result["advanced"], 1)
        status = self.service.plot_status(SAVE)
        plot = status["plots"][0]
        self.assertEqual(plot["current_beat"]["id"], "b1")
        # 第 3 天:b1 退出(写记忆) + b2 进入
        self._tick(3.5)
        self.assertEqual(self.service.plot_status(SAVE)["plots"][0]["current_beat"]["id"], "b2")
        terms = self.store.beat_memory_terms(SAVE, "ling")
        self.assertIn(f"{BEAT_TERM_PREFIX}p1/b1", terms)
        actions = {row["action"] for row in self.store.list_life_events(save_id=SAVE)}
        self.assertIn("plot", actions)
        # 第 6 天:枢轴激活,且带两个选项
        self._tick(6.0)
        current = self.service.plot_status(SAVE)["plots"][0]["current_beat"]
        self.assertEqual(current["id"], "pivot")
        self.assertEqual([c["id"] for c in current["choices"]], ["stay", "milk"])
        # 玩家选择:记忆 + 事件 + 心境都落库
        payload = self.service.apply_plot_choice(
            {"save_id": SAVE, "plot_id": "p1", "choice_id": "stay", "now": self._at(6.5)}
        )
        self.assertIsNone(payload["plots"][0]["current_beat"])
        self.assertEqual(payload["plots"][0]["history"][-1]["resolution"], "stay")
        event_ids = {row["event_id"] for row in self.store.list_life_events(save_id=SAVE)}
        self.assertIn("plot-p1-pivot-stay", event_ids)
        self.assertIn(f"{BEAT_TERM_PREFIX}p1/pivot", self.store.beat_memory_terms(SAVE, "ling"))

    def test_choice_validation(self) -> None:
        with self.assertRaises(RequestValidationError):
            self.service.apply_plot_choice(
                {"save_id": SAVE, "plot_id": "p1", "choice_id": "stay", "now": self._at(1.0)}
            )  # 枢轴还没激活
        self._tick(6.0)
        with self.assertRaises(RequestValidationError):
            self.service.apply_plot_choice(
                {"save_id": SAVE, "plot_id": "p1", "choice_id": "nope", "now": self._at(6.0)}
            )
        with self.assertRaises(RequestValidationError):
            self.service.apply_plot_choice(
                {"save_id": SAVE, "plot_id": "ghost", "choice_id": "stay", "now": self._at(6.0)}
            )

    def test_timeout_is_a_valid_ending(self) -> None:
        self._tick(6.0)  # 第一次求值:b1 进入(空状态只进场,不退出)
        self._tick(6.0)  # b1 退出 + b2 进入(同刻)
        self._tick(9.0)  # b2 退出 + 枢轴激活(同刻)
        self._tick(12.0)  # 枢轴 TTL 2 天无人选择 → alone
        history = self.service.plot_status(SAVE)["plots"][0]["history"]
        self.assertEqual(history[-1]["resolution"], "alone")

    def test_rerun_is_idempotent(self) -> None:
        first = self._tick(1.5)
        again = self._tick(1.5)
        self.assertGreaterEqual(first["advanced"], 1)
        self.assertEqual(again["advanced"], 0)

    def test_empty_library_noops(self) -> None:
        self.service.beats = BeatLibrary.empty()
        # 空库在读存档清单之前就短路:零成本,自然零推进
        result = self._tick(3.0)
        self.assertEqual(result, {"due": 0, "advanced": 0, "failed": 0})


if __name__ == "__main__":
    unittest.main()
