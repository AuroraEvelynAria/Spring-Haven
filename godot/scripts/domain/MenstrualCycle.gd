class_name MenstrualCycle
extends RefCounted

const PROTOCOL := "spring_heaven.menstrual_cycle.v1"
const SECONDS_PER_DAY := 24 * 60 * 60

const ROLE_PROFILES := {
	"ling": {
		"cycle_length_days": 29,
		"period_length_days": 5,
		"initial_cycle_day": 3,
		"symptom_sensitivity": 1.0,
		"contraceptive_dose_units": 1.0,
		"contraceptive_residual_factor": 0.05,
	},
	"nai": {
		"cycle_length_days": 27,
		"period_length_days": 4,
		"initial_cycle_day": 17,
		"symptom_sensitivity": 0.84,
		"contraceptive_dose_units": 0.5,
		"contraceptive_residual_factor": 0.05,
	},
}

static var _profile_overrides: Dictionary = {}
static var _seconds_per_day := SECONDS_PER_DAY

static func configure_runtime_tuning(values: Dictionary) -> void:
	_profile_overrides.clear()
	var time_scale := clampf(float(values.get("cycle_time_scale", 1.0)), 0.1, 10.0)
	_seconds_per_day = maxi(60, int(round(float(SECONDS_PER_DAY) / time_scale)))
	for role in ["ling", "nai"]:
		_profile_overrides[role] = {
			"cycle_length_days": int(values.get(
				"%s_cycle_length_days" % role,
				(ROLE_PROFILES[role] as Dictionary).cycle_length_days
			)),
			"period_length_days": int(values.get(
				"%s_period_length_days" % role,
				(ROLE_PROFILES[role] as Dictionary).period_length_days
			)),
			"initial_cycle_day": int(values.get(
				"%s_initial_cycle_day" % role,
				(ROLE_PROFILES[role] as Dictionary).initial_cycle_day
			)),
			"symptom_sensitivity": float(values.get(
				"%s_symptom_scale" % role,
				(ROLE_PROFILES[role] as Dictionary).symptom_sensitivity
			)),
		}

const PHASE_LABELS := {
	"menstrual": "经期",
	"follicular": "卵泡期",
	"ovulation": "排卵窗口",
	"luteal": "黄体期",
}

static func normalize_runtime(
	role: String,
	raw_value: Variant,
	now_unix: int
) -> Dictionary:
	var profile := profile_for_role(role)
	var raw: Dictionary = raw_value if raw_value is Dictionary else {}
	var default_started_at := now_unix - (
		int(profile.initial_cycle_day) - 1
	) * _seconds_per_day
	var started_at := _normalized_unix_time(
		raw.get("started_at_unix", default_started_at),
		default_started_at
	)
	if started_at > now_unix:
		started_at = now_unix
	var current_absolute_day := absolute_day_index(started_at, now_unix)
	var current := snapshot_from_absolute_day(role, current_absolute_day, now_unix)
	var last_processed := _normalized_index(
		raw.get("last_processed_day_index", current_absolute_day),
		current_absolute_day,
		current_absolute_day
	)
	var last_fertility_sync := _normalized_index(
		raw.get("last_fertility_sync_day_index", -1),
		-1,
		current_absolute_day
	)
	var last_phase := str(raw.get("last_phase", current.phase))
	if not PHASE_LABELS.has(last_phase):
		last_phase = str(current.phase)
	return {
		"started_at_unix": started_at,
		"last_processed_day_index": last_processed,
		"last_fertility_sync_day_index": last_fertility_sync,
		"last_phase": last_phase,
		"last_cycle_number": clampi(
			int(raw.get("last_cycle_number", current.cycle_number)),
			0,
			current.cycle_number
		),
		"last_cycle_day": clampi(
			int(raw.get("last_cycle_day", current.cycle_day)),
			1,
			int(profile.cycle_length_days)
		),
	}

static func current_snapshot(role: String, runtime: Dictionary, now_unix: int) -> Dictionary:
	var normalized := normalize_runtime(role, runtime, now_unix)
	var absolute_day := absolute_day_index(int(normalized.started_at_unix), now_unix)
	return snapshot_from_absolute_day(role, absolute_day, now_unix)

static func snapshot_from_absolute_day(
	role: String,
	absolute_day: int,
	observed_at_unix: int
) -> Dictionary:
	var profile := profile_for_role(role)
	var cycle_length := int(profile.cycle_length_days)
	var period_length := int(profile.period_length_days)
	var safe_absolute_day := maxi(0, absolute_day)
	var cycle_number := safe_absolute_day / cycle_length
	var cycle_day := safe_absolute_day % cycle_length + 1
	var ovulation_day := cycle_length - 14
	var phase := _phase_for_day(cycle_day, period_length, ovulation_day)
	var bleeding := _bleeding_for_day(cycle_day, period_length)
	var cramps_score := _cramps_score(
		cycle_day,
		cycle_length,
		period_length,
		float(profile.symptom_sensitivity)
	)
	var fertile_window := cycle_day >= ovulation_day - 5 and cycle_day <= ovulation_day + 1
	var receptivity := endometrial_receptivity_index(role, cycle_day, cycle_length, period_length)
	var contraception_active := true
	var implantation_likelihood := effective_implantation_likelihood_index(
		receptivity,
		contraception_active,
		float(profile.contraceptive_residual_factor)
	)
	return {
		"protocol": PROTOCOL,
		"role_id": role,
		"observed_at_unix": observed_at_unix,
		"phase": phase,
		"phase_label": str(PHASE_LABELS[phase]),
		"cycle_day": cycle_day,
		"cycle_length_days": cycle_length,
		"period_length_days": period_length,
		"ovulation_day": ovulation_day,
		"fertile_window": fertile_window,
		"premenstrual": cycle_day > cycle_length - 4,
		"bleeding": bleeding,
		"cramps": _symptom_level(cramps_score),
		"cramps_score": cramps_score,
		"days_until_next_period": cycle_length - cycle_day + 1,
		"endometrial_receptivity_index": receptivity,
		"contraception_active": contraception_active,
		"contraceptive_dose_units": float(profile.contraceptive_dose_units),
		"contraceptive_side_effects": false,
		"effective_implantation_likelihood_index": implantation_likelihood,
		"cycle_number": cycle_number,
		"absolute_day_index": safe_absolute_day,
	}

static func daily_stat_effect(role: String, snapshot: Dictionary) -> Dictionary:
	var sensitivity := float(profile_for_role(role).symptom_sensitivity)
	var phase := str(snapshot.get("phase", "follicular"))
	var cycle_day := int(snapshot.get("cycle_day", 1))
	var cycle_length := int(snapshot.get("cycle_length_days", 28))
	var updates: Dictionary = {}
	if phase == "menstrual":
		var first_days := 1.0 if cycle_day <= 2 else 0.65
		updates = {
			"stamina": -1.1 * sensitivity * first_days,
			"mood": -0.45 * sensitivity * first_days,
			"stress": 0.65 * sensitivity * first_days,
			"thirst": 0.25 * sensitivity,
		}
	elif cycle_day > cycle_length - 4:
		updates = {
			"stamina": -0.35 * sensitivity,
			"mood": -0.55 * sensitivity,
			"stress": 0.75 * sensitivity,
		}
	elif phase == "ovulation":
		updates = {
			"mood": 0.35,
		}
	return updates

static func endometrial_receptivity_index(
	_role: String,
	cycle_day: int,
	cycle_length: int,
	period_length: int
) -> float:
	if cycle_day <= period_length:
		return 2.0
	var ovulation_day := cycle_length - 14
	if cycle_day <= ovulation_day + 2:
		return clampf(6.0 + float(cycle_day - period_length) * 1.8, 6.0, 30.0)
	var receptive_peak_day := ovulation_day + 7
	var distance := absf(float(cycle_day - receptive_peak_day))
	return snappedf(clampf(100.0 - distance * 16.0, 12.0, 100.0), 0.1)

static func effective_implantation_likelihood_index(
	natural_receptivity_index: float,
	contraception_active: bool,
	residual_factor: float
) -> float:
	var natural_index := clampf(natural_receptivity_index, 0.0, 100.0)
	if not contraception_active:
		return snappedf(natural_index, 0.1)
	return snappedf(
		clampf(natural_index * clampf(residual_factor, 0.0, 1.0), 0.0, 100.0),
		0.1
	)

static func profile_for_role(role: String) -> Dictionary:
	var safe_role := role if ROLE_PROFILES.has(role) else "ling"
	var profile := (ROLE_PROFILES[safe_role] as Dictionary).duplicate(true)
	var override = _profile_overrides.get(safe_role, {})
	if override is Dictionary:
		for key in override:
			profile[key] = override[key]
	profile["period_length_days"] = mini(
		int(profile.period_length_days), int(profile.cycle_length_days) - 15
	)
	profile["initial_cycle_day"] = clampi(
		int(profile.initial_cycle_day), 1, int(profile.cycle_length_days)
	)
	return profile

static func absolute_day_index(started_at_unix: int, now_unix: int) -> int:
	return maxi(0, int(floor(float(maxi(0, now_unix - started_at_unix)) / float(_seconds_per_day))))

static func public_snapshot(snapshot: Dictionary) -> Dictionary:
	var result := snapshot.duplicate(true)
	result.erase("cycle_number")
	result.erase("absolute_day_index")
	result.erase("phase_label")
	return result

static func _phase_for_day(cycle_day: int, period_length: int, ovulation_day: int) -> String:
	if cycle_day <= period_length:
		return "menstrual"
	if cycle_day < ovulation_day - 1:
		return "follicular"
	if cycle_day <= ovulation_day + 1:
		return "ovulation"
	return "luteal"

static func _bleeding_for_day(cycle_day: int, period_length: int) -> String:
	if cycle_day > period_length:
		return "none"
	if cycle_day == 1:
		return "moderate"
	if cycle_day == 2:
		return "heavy"
	if cycle_day >= period_length - 1:
		return "light"
	return "moderate"

static func _cramps_score(
	cycle_day: int,
	cycle_length: int,
	period_length: int,
	sensitivity: float
) -> float:
	var score := 0.0
	if cycle_day <= period_length:
		score = [68.0, 58.0, 34.0, 20.0, 12.0][mini(cycle_day - 1, 4)]
	elif cycle_day > cycle_length - 4:
		score = 22.0 + float(cycle_day - (cycle_length - 4)) * 4.0
	return snappedf(clampf(score * sensitivity, 0.0, 100.0), 0.1)

static func _symptom_level(score: float) -> String:
	if score >= 60.0:
		return "strong"
	if score >= 35.0:
		return "moderate"
	if score > 0.0:
		return "mild"
	return "none"

static func _normalized_unix_time(value: Variant, fallback: int) -> int:
	if value is bool or not (value is int or value is float):
		return fallback
	var numeric := float(value)
	if not is_finite(numeric) or numeric < 0.0:
		return fallback
	return int(numeric)

static func _normalized_index(value: Variant, fallback: int, maximum: int) -> int:
	if value is bool or not (value is int or value is float):
		return fallback
	var numeric := float(value)
	if not is_finite(numeric):
		return fallback
	return clampi(int(numeric), -1, maximum)
