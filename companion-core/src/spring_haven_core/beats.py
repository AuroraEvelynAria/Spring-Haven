"""ADR-016:故事脊椎与节拍。

节拍是「她的心事」,不是「玩家的任务」:作者写条件与动机(goal),
台词与演绎由 LLM 结合她自己的记忆生成;本模块只做**决策**——
条件求值与状态机推进是纯函数,零 LLM、可复现(验收判据 2)。

副作用(写记忆/写事件/心境冲击)全部由 service 层在拿到决策后执行,
且都带确定性 source_event_id / event_id,重放幂等。

数据模型(与 ADR-016 对应,脊椎 = beats 数组顺序):
    PlotDefinition   ≙ plots 行(内容在 JSON 文件里,不进库)
    BeatDefinition   ≙ beats 行
    plot_state 表    ≙ beat_state(运行时,按存档)

条件语言(全部可判定,数据源来自已有系统):
    {"world_day": {"gte": 12, "lte": 20}}        世界日窗口
    {"stat": {"role": "ling", "key": "stress", "gte": 50}}
    {"life_event": {"role": "nai", "action": "quiet_time",
                    "within_world_days": 2, "count_gte": 1}}
    {"memory_term": {"role": "ling", "term": "beat:first-thunder/forecast"}}
    {"beat_exited": {"beat": "forecast"}}
    {"all": [...]}, {"any": [...]}, {"not": {...}}
不允许出现自然语言判断题——那会变成"许愿"。
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PLOT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
BEAT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
CHOICE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

# 节拍记忆的检索触发词前缀。写入路径(service)与求值路径(memory_term 条件/
# store.beat_memory_terms)共用同一份,与自主事件指纹同一纪律。
BEAT_TERM_PREFIX = "beat:"

# 节拍事件在 life_events 里的 action 名(自由文本约定,供时间线过滤)。
PLOT_ACTION = "plot"

# 线性节拍的退出结果名;枢轴节拍的 resolution 是命中的 choice_id。
RESOLUTION_COMPLETED = "completed"
RESOLUTION_EXPIRED = "expired"

# 条件里允许的比较键(world_day / stat 共用)。
_COMPARATORS = {"gte", "lte", "gt", "lt"}


class BeatConfigurationError(ValueError):
    """Raised when a plot file or condition cannot safely be loaded."""


@dataclass(frozen=True)
class OutcomeSpec:
    """节拍退出/选择命中时要执行的动作(纯数据;副作用在 service 层)。

    memory: put_memory 入参的子集(kind/title/content/importance/valence/trigger_terms);
            content 必填,trigger_terms 会被自动并入 "beat:{plot_id}/{beat_id}"。
    mood:   {"p": .., "a": .., "d": ..} 的 PAD 增量(逐维限幅在 store 层)。
    """

    memory: dict[str, Any] | None = None
    mood: dict[str, Any] | None = None


@dataclass(frozen=True)
class ChoiceSpec:
    """枢轴节拍的一个显式选项。"""

    choice_id: str
    label: str
    outcome: OutcomeSpec


@dataclass(frozen=True)
class BeatDefinition:
    beat_id: str
    role: str
    title: str
    goal: str
    enter_when: dict[str, Any]
    exit_when: dict[str, Any] | None
    ttl_world_days: float | None
    outcome: OutcomeSpec  # 正常完成(completed)时的动作
    expire_outcome: OutcomeSpec | None  # 超时(expired)时的动作;None=只记账
    choices: tuple[ChoiceSpec, ...]  # 枢轴节拍非空;此时 exit_when 必须为 None
    timeout_choice: ChoiceSpec | None  # 枢轴超时的默认去向(缺席是合法结局)

    @property
    def is_pivot(self) -> bool:
        return bool(self.choices)

    def choice(self, choice_id: str) -> ChoiceSpec | None:
        for item in self.choices:
            if item.choice_id == choice_id:
                return item
        return None


@dataclass(frozen=True)
class PlotDefinition:
    plot_id: str
    title: str
    beats: tuple[BeatDefinition, ...]  # 按脊椎顺序;数组顺序即脊椎

    def beat(self, beat_id: str) -> BeatDefinition | None:
        for item in self.beats:
            if item.beat_id == beat_id:
                return item
        return None


@dataclass(frozen=True)
class WorldFacts:
    """一次求值可用的全部事实。求值器只认这个快照,不碰库。"""

    world_day: float
    stats: dict[str, dict[str, float]]  # role_id -> stat key -> value
    life_events: tuple[dict[str, Any], ...]  # 需含 role_id/action/world_occurred_at
    memory_terms: dict[str, frozenset[str]]  # role_id -> beat:* 触发词集合
    exited_beats: frozenset[str]  # 本脊椎已退出的 beat_id


@dataclass(frozen=True)
class BeatTransition:
    """一步决策;service 层按它落副作用。"""

    kind: str  # "enter" | "exit"
    plot_id: str
    beat_id: str
    role: str
    title: str  # 节拍标题(事件描述用)
    resolution: str  # exit 时: completed/expired/<choice_id>
    world_day: float
    outcome: OutcomeSpec | None  # 仅 exit 携带
    label: str  # 枢轴选项的展示文案(exit 时有值,enter 时为空)


def evaluate_condition(condition: Any, facts: WorldFacts) -> bool:
    """纯函数条件求值。未知算子抛 BeatConfigurationError(装配期已校验,这里是兜底)。"""
    if not isinstance(condition, dict) or not condition:
        raise BeatConfigurationError("condition must be a non-empty object")
    for operator, operand in condition.items():
        if operator == "all":
            return all(evaluate_condition(item, facts) for item in _as_list(operand, "all"))
        if operator == "any":
            return any(evaluate_condition(item, facts) for item in _as_list(operand, "any"))
        if operator == "not":
            return not evaluate_condition(operand, facts)
        if operator == "world_day":
            return _compare(facts.world_day, _comparators(operand, "world_day"))
        if operator == "stat":
            return _eval_stat(operand, facts)
        if operator == "life_event":
            return _eval_life_event(operand, facts)
        if operator == "memory_term":
            return _eval_memory_term(operand, facts)
        if operator == "beat_exited":
            return _eval_beat_exited(operand, facts)
        raise BeatConfigurationError(f"unknown condition operator: {operator!r}")
    return True  # 空对象不会发生(上方已拦截),仅满足类型检查


def advance_plot_state(
    plot: PlotDefinition,
    state: dict[str, Any],
    facts: WorldFacts,
) -> tuple[dict[str, Any], list[BeatTransition]]:
    """状态机一步:先退出当前节拍,再(同刻)尝试进入下一拍。纯函数。

    state 形如 {"current_beat_id", "entered_world_day", "started_world_day",
    "history": [{beat_id, entered_world_day, exited_world_day, resolution}]}。
    """
    current = str(state.get("current_beat_id", ""))
    entered = float(state.get("entered_world_day", 0.0))
    started = float(state.get("started_world_day", 0.0))
    history: list[dict[str, Any]] = [
        dict(item) for item in state.get("history", []) if isinstance(item, dict)
    ]
    transitions: list[BeatTransition] = []

    if current:
        beat = plot.beat(current)
        if beat is None:
            # 内容被改掉后旧存档可能挂着不存在的节拍:记账后释放,不再前进,
            # 让下一拍按 enter_when 正常接棒(坏内容不应当卡死整个状态机)。
            history.append(
                {
                    "beat_id": current,
                    "entered_world_day": entered,
                    "exited_world_day": facts.world_day,
                    "resolution": RESOLUTION_EXPIRED,
                }
            )
            transitions.append(
                BeatTransition("exit", plot.plot_id, current, "", "", RESOLUTION_EXPIRED,
                               facts.world_day, None, "")
            )
            current = ""
        else:
            resolution, outcome, label = _decide_exit(beat, entered, facts)
            if resolution is not None:
                history.append(
                    {
                        "beat_id": current,
                        "entered_world_day": entered,
                        "exited_world_day": facts.world_day,
                        "resolution": resolution,
                    }
                )
                transitions.append(
                    BeatTransition("exit", plot.plot_id, current, beat.role, beat.title,
                                   resolution, facts.world_day, outcome, label)
                )
                current = ""

    if not current:
        exited = {str(item.get("beat_id", "")) for item in history}
        for beat in plot.beats:  # 线性脊椎:第一拍未退出则后面不许跳入
            if beat.beat_id in exited:
                continue
            if evaluate_condition(beat.enter_when, facts):
                current = beat.beat_id
                entered = facts.world_day
                if started <= 0.0:
                    started = facts.world_day
                transitions.append(
                    BeatTransition("enter", plot.plot_id, beat.beat_id, beat.role,
                                   beat.title, "", facts.world_day, None, "")
                )
            break  # 无论是否满足,候选只看脊椎上的下一拍

    new_state = {
        "current_beat_id": current,
        "entered_world_day": entered,
        "started_world_day": started,
        "history": history,
    }
    return new_state, transitions


def resolve_plot_choice(
    plot: PlotDefinition,
    state: dict[str, Any],
    choice_id: str,
    facts: WorldFacts,
) -> tuple[dict[str, Any], BeatTransition]:
    """枢轴节拍的显式选择。当前拍必须是枢轴且 choice 合法,否则抛错。"""
    current = str(state.get("current_beat_id", ""))
    beat = plot.beat(current)
    if beat is None or not beat.is_pivot:
        raise BeatConfigurationError(f"plot {plot.plot_id} has no pivot beat active")
    chosen = beat.choice(choice_id)
    if chosen is None:
        raise BeatConfigurationError(
            f"beat {beat.beat_id} has no choice: {choice_id!r}"
        )
    entered = float(state.get("entered_world_day", 0.0))
    history = [
        dict(item) for item in state.get("history", []) if isinstance(item, dict)
    ]
    history.append(
        {
            "beat_id": beat.beat_id,
            "entered_world_day": entered,
            "exited_world_day": facts.world_day,
            "resolution": chosen.choice_id,
        }
    )
    transition = BeatTransition(
        "exit", plot.plot_id, beat.beat_id, beat.role, beat.title, chosen.choice_id,
        facts.world_day, chosen.outcome, chosen.label,
    )
    new_state = {
        "current_beat_id": "",
        "entered_world_day": 0.0,
        "started_world_day": float(state.get("started_world_day", 0.0)),
        "history": history,
    }
    return new_state, transition


def plot_finished(state: dict[str, Any], plot: PlotDefinition) -> bool:
    """脊椎收束:全部节拍都已退出且无当前拍。"""
    if str(state.get("current_beat_id", "")):
        return False
    exited = {
        str(item.get("beat_id", "")) for item in state.get("history", []) if isinstance(item, dict)
    }
    return all(beat.beat_id in exited for beat in plot.beats)


# ===== 加载与校验 =====


class BeatLibrary:
    """已装载的剧本集合。内容是可选件:目录缺失/为空 → 空库,服务照常启动。"""

    def __init__(self, plots: dict[str, PlotDefinition]):
        self._plots = dict(plots)

    @classmethod
    def empty(cls) -> "BeatLibrary":
        return cls({})

    @classmethod
    def load_dir(cls, path: str | Path, allowed_roles: tuple[str, ...] | list[str]) -> "BeatLibrary":
        root = Path(path)
        if not root.is_dir():
            return cls.empty()
        roles = tuple(dict.fromkeys(str(item) for item in allowed_roles))
        plots: dict[str, PlotDefinition] = {}
        for file in sorted(root.glob("*.json")):
            try:
                parsed = json.loads(file.read_text(encoding="utf-8-sig"))
            except json.JSONDecodeError as exc:
                raise BeatConfigurationError(f"{file.name} is not valid JSON: {exc}") from exc
            for plot in _parse_plots(parsed, file.name, roles):
                if plot.plot_id in plots:
                    raise BeatConfigurationError(f"duplicate plot_id: {plot.plot_id}")
                plots[plot.plot_id] = plot
        return cls(plots)

    def plots(self) -> list[PlotDefinition]:
        return list(self._plots.values())

    def get(self, plot_id: str) -> PlotDefinition:
        try:
            return self._plots[plot_id]
        except KeyError as exc:
            raise BeatConfigurationError(f"unknown plot_id: {plot_id}") from exc


def _parse_plots(
    parsed: Any, source_name: str, allowed_roles: tuple[str, ...]
) -> list[PlotDefinition]:
    if not isinstance(parsed, dict):
        raise BeatConfigurationError(f"{source_name} must contain a JSON object")
    raw_plots = parsed.get("plots")
    if not isinstance(raw_plots, list):
        raise BeatConfigurationError(f"{source_name} must contain a plots array")
    plots: list[PlotDefinition] = []
    for raw in raw_plots:
        if not isinstance(raw, dict):
            raise BeatConfigurationError(f"{source_name}: each plot must be an object")
        plot_id = str(raw.get("plot_id", "")).strip()
        if not PLOT_ID_PATTERN.fullmatch(plot_id):
            raise BeatConfigurationError(f"{source_name}: invalid plot_id {plot_id!r}")
        title = str(raw.get("title", "")).strip()
        if not title or len(title) > 120:
            raise BeatConfigurationError(f"{source_name}: invalid title for {plot_id}")
        raw_beats = raw.get("beats")
        if not isinstance(raw_beats, list) or not raw_beats:
            raise BeatConfigurationError(f"{source_name}: {plot_id} needs a non-empty beats array")
        seen: set[str] = set()
        beats: list[BeatDefinition] = []
        for item in raw_beats:
            beat = _parse_beat(item, source_name, plot_id, allowed_roles)
            if beat.beat_id in seen:
                raise BeatConfigurationError(
                    f"{source_name}: duplicate beat id {beat.beat_id!r} in {plot_id}"
                )
            seen.add(beat.beat_id)
            beats.append(beat)
        # 脊椎里只有首拍允许没有 enter_when(缺省永真)
        plots.append(PlotDefinition(plot_id=plot_id, title=title, beats=tuple(beats)))
    return plots


def _parse_beat(
    raw: Any, source_name: str, plot_id: str, allowed_roles: tuple[str, ...]
) -> BeatDefinition:
    if not isinstance(raw, dict):
        raise BeatConfigurationError(f"{source_name}: each beat must be an object")
    beat_id = str(raw.get("id", "")).strip()
    if not BEAT_ID_PATTERN.fullmatch(beat_id):
        raise BeatConfigurationError(f"{source_name}: invalid beat id {beat_id!r}")
    role = str(raw.get("role", "")).strip()
    if role not in allowed_roles:
        raise BeatConfigurationError(
            f"{source_name}: beat {beat_id} has unknown role {role!r}"
        )
    title = str(raw.get("title", "")).strip()
    goal = str(raw.get("goal", "")).strip()
    if not title or not goal or len(title) > 120 or len(goal) > 200:
        raise BeatConfigurationError(
            f"{source_name}: beat {beat_id} needs a title and a goal (<=200 chars)"
        )
    enter_when = raw.get("enter_when", {"world_day": {"gte": 0}})
    _validate_condition(enter_when, f"{source_name}:{plot_id}/{beat_id}.enter_when")
    exit_when = raw.get("exit_when")
    if exit_when is not None:
        _validate_condition(exit_when, f"{source_name}:{plot_id}/{beat_id}.exit_when")
    ttl_raw = raw.get("beats_ttl_world_days")
    ttl = float(ttl_raw) if ttl_raw is not None else None
    if ttl is not None and (not ttl > 0):
        raise BeatConfigurationError(
            f"{source_name}: beat {beat_id} beats_ttl_world_days must be positive"
        )
    outcome = _parse_outcome(raw.get("on_exit"), f"{source_name}:{beat_id}.on_exit")
    expire_raw = raw.get("on_expire")
    expire_outcome = (
        _parse_outcome(expire_raw, f"{source_name}:{beat_id}.on_expire")
        if expire_raw is not None
        else None
    )
    choices_raw = raw.get("choices", [])
    if not isinstance(choices_raw, list):
        raise BeatConfigurationError(f"{source_name}: choices must be an array ({beat_id})")
    choices = tuple(
        _parse_choice(item, f"{source_name}:{beat_id}.choices[{index}]")
        for index, item in enumerate(choices_raw)
    )
    timeout_raw = raw.get("timeout_choice")
    timeout_choice = (
        _parse_choice(timeout_raw, f"{source_name}:{beat_id}.timeout_choice")
        if timeout_raw is not None
        else None
    )
    if choices:
        # 枢轴:只靠选择/超时退出,不允许再写 exit_when(否则语义二义)
        if exit_when is not None:
            raise BeatConfigurationError(
                f"{source_name}: pivot beat {beat_id} must not define exit_when"
            )
        if timeout_choice is None:
            raise BeatConfigurationError(
                f"{source_name}: pivot beat {beat_id} needs timeout_choice(缺席是合法结局)"
            )
    else:
        if exit_when is None and ttl is None:
            raise BeatConfigurationError(
                f"{source_name}: beat {beat_id} needs exit_when or beats_ttl_world_days"
            )
    return BeatDefinition(
        beat_id=beat_id,
        role=role,
        title=title,
        goal=goal,
        enter_when=enter_when,
        exit_when=exit_when,
        ttl_world_days=ttl,
        outcome=outcome,
        expire_outcome=expire_outcome,
        choices=choices,
        timeout_choice=timeout_choice,
    )


def _parse_choice(raw: Any, where: str) -> ChoiceSpec:
    if not isinstance(raw, dict):
        raise BeatConfigurationError(f"{where} must be an object")
    choice_id = str(raw.get("id", "")).strip()
    if not CHOICE_ID_PATTERN.fullmatch(choice_id):
        raise BeatConfigurationError(f"{where}: invalid choice id {choice_id!r}")
    label = str(raw.get("label", "")).strip()
    if not label or len(label) > 80:
        raise BeatConfigurationError(f"{where}: choice needs a label (<=80 chars)")
    outcome = _parse_outcome(raw.get("outcome"), f"{where}.outcome")
    return ChoiceSpec(choice_id=choice_id, label=label, outcome=outcome)


def _parse_outcome(raw: Any, where: str) -> OutcomeSpec:
    if raw is None:
        return OutcomeSpec()
    if not isinstance(raw, dict):
        raise BeatConfigurationError(f"{where} must be an object")
    memory = raw.get("memory")
    if memory is not None:
        if not isinstance(memory, dict):
            raise BeatConfigurationError(f"{where}.memory must be an object")
        content = str(memory.get("content", "")).strip()
        if not content or len(content) > 2000:
            raise BeatConfigurationError(f"{where}.memory needs content (<=2000 chars)")
        if str(memory.get("title", "")).strip() == "":
            raise BeatConfigurationError(f"{where}.memory needs a title")
    mood = raw.get("mood")
    if mood is not None and not isinstance(mood, dict):
        raise BeatConfigurationError(f"{where}.mood must be an object")
    return OutcomeSpec(memory=memory, mood=mood)


def _validate_condition(condition: Any, where: str) -> None:
    """装配期结构校验(与求值同一套算子表),坏内容在启动时炸而不是运行时。"""
    if not isinstance(condition, dict) or not condition:
        raise BeatConfigurationError(f"{where}: condition must be a non-empty object")
    for operator, operand in condition.items():
        if operator in {"all", "any"}:
            items = _as_list(operand, operator)
            if not items:
                raise BeatConfigurationError(f"{where}.{operator} must not be empty")
            for item in items:
                _validate_condition(item, f"{where}.{operator}[]")
        elif operator == "not":
            _validate_condition(operand, f"{where}.not")
        elif operator == "world_day":
            _comparators(operand, f"{where}.world_day")
        elif operator == "stat":
            if not isinstance(operand, dict) or not str(operand.get("role", "")).strip():
                raise BeatConfigurationError(f"{where}.stat needs role")
            if not str(operand.get("key", "")).strip():
                raise BeatConfigurationError(f"{where}.stat needs key")
            _comparators(
                {key: value for key, value in operand.items() if key in _COMPARATORS},
                f"{where}.stat",
            )
        elif operator == "life_event":
            if not isinstance(operand, dict) or not str(operand.get("action", "")).strip():
                raise BeatConfigurationError(f"{where}.life_event needs action")
            window = operand.get("within_world_days", 1)
            if not isinstance(window, (int, float)) or not window > 0:
                raise BeatConfigurationError(f"{where}.life_event within_world_days must be > 0")
        elif operator == "memory_term":
            if not isinstance(operand, dict) or not str(operand.get("term", "")).strip():
                raise BeatConfigurationError(f"{where}.memory_term needs term")
        elif operator == "beat_exited":
            if not isinstance(operand, dict) or not str(operand.get("beat", "")).strip():
                raise BeatConfigurationError(f"{where}.beat_exited needs beat")
        else:
            raise BeatConfigurationError(f"{where}: unknown condition operator {operator!r}")


# ===== 条件叶子的实现 =====


def _as_list(operand: Any, operator: str) -> list[Any]:
    if not isinstance(operand, list):
        raise BeatConfigurationError(f"{operator} operand must be an array")
    return operand


def _comparators(operand: Any, where: str) -> dict[str, float]:
    if not isinstance(operand, dict) or not operand:
        raise BeatConfigurationError(f"{where} needs at least one comparator")
    parsed: dict[str, float] = {}
    for key, value in operand.items():
        if key not in _COMPARATORS:
            raise BeatConfigurationError(f"{where}: unknown comparator {key!r}")
        try:
            parsed[key] = float(value)
        except (TypeError, ValueError) as exc:
            raise BeatConfigurationError(f"{where}: {key} must be numeric") from exc
    return parsed


def _compare(value: float, bounds: dict[str, float]) -> bool:
    if "gte" in bounds and value < bounds["gte"]:
        return False
    if "lte" in bounds and value > bounds["lte"]:
        return False
    if "gt" in bounds and value <= bounds["gt"]:
        return False
    if "lt" in bounds and value >= bounds["lt"]:
        return False
    return True


def _eval_stat(operand: Any, facts: WorldFacts) -> bool:
    role = str(operand.get("role", "")).strip()
    key = str(operand.get("key", "")).strip()
    bounds = _comparators(
        {key: value for key, value in operand.items() if key in _COMPARATORS}, "stat"
    )
    value = facts.stats.get(role, {}).get(key)
    if value is None:
        return False  # 快照里没有的属性不成立,而不是报错(客户端没同步就还没发生)
    return _compare(float(value), bounds)


def _eval_life_event(operand: Any, facts: WorldFacts) -> bool:
    role = str(operand.get("role", "")).strip()
    action = str(operand.get("action", "")).strip()
    window = float(operand.get("within_world_days", 1))
    count_gte = max(1, int(operand.get("count_gte", 1)))
    lower = facts.world_day - window
    hits = 0
    for event in facts.life_events:
        if str(event.get("action", "")) != action:
            continue
        if role and str(event.get("role_id", "")) != role:
            continue
        try:
            occurred = float(event.get("world_occurred_at", 0.0))
        except (TypeError, ValueError):
            continue
        if lower <= occurred <= facts.world_day:
            hits += 1
            if hits >= count_gte:
                return True
    return False


def _eval_memory_term(operand: Any, facts: WorldFacts) -> bool:
    role = str(operand.get("role", "")).strip()
    term = str(operand.get("term", "")).strip()
    return term in facts.memory_terms.get(role, frozenset())


def _eval_beat_exited(operand: Any, facts: WorldFacts) -> bool:
    beat_id = str(operand.get("beat", "")).strip()
    return beat_id in facts.exited_beats


def _decide_exit(
    beat: BeatDefinition, entered_world_day: float, facts: WorldFacts
) -> tuple[str | None, OutcomeSpec | None, str]:
    """返回 (resolution, outcome, label);resolution None = 本拍继续。"""
    if beat.is_pivot:
        if beat.ttl_world_days is not None and facts.world_day - entered_world_day >= beat.ttl_world_days:
            assert beat.timeout_choice is not None  # 装配期已强制
            return beat.timeout_choice.choice_id, beat.timeout_choice.outcome, beat.timeout_choice.label
        return None, None, ""
    if beat.exit_when is not None and evaluate_condition(beat.exit_when, facts):
        return RESOLUTION_COMPLETED, beat.outcome, ""
    if beat.ttl_world_days is not None and facts.world_day - entered_world_day >= beat.ttl_world_days:
        return RESOLUTION_EXPIRED, beat.expire_outcome, ""
    return None, None, ""
