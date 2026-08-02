class_name PerceptionRay3D
extends Node3D

@export_range(0.5, 20.0, 0.1) var max_distance := 8.0
@export_range(1, 8, 1) var max_hits := 4
@export_flags_3d_physics var collision_mask := 1
@export_enum("ling", "nai") var observer_role_id := "ling"

func scan() -> Dictionary:
	if not is_inside_tree() or get_world_3d() == null:
		return _empty_result()
	var origin := global_position
	var direction := -global_transform.basis.z.normalized()
	var target := origin + direction * max_distance
	var exclusions: Array[RID] = []
	var observations: Array[Dictionary] = []
	var space := get_world_3d().direct_space_state
	for _index in max_hits:
		var query := PhysicsRayQueryParameters3D.create(origin, target, collision_mask, exclusions)
		query.collide_with_areas = true
		query.collide_with_bodies = true
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			break
		var collider = hit.get("collider")
		var perceivable := _find_perceivable(collider as Node)
		var transparent := false
		if is_instance_valid(perceivable):
			var snapshot_variant = perceivable.call("get_perception_snapshot", self)
			if snapshot_variant is Dictionary:
				var snapshot: Dictionary = snapshot_variant
				snapshot["distance_m"] = snappedf(origin.distance_to(hit.position), 0.1)
				observations.append(snapshot)
				transparent = bool(snapshot.get("transparent", false))
		if collider is CollisionObject3D:
			exclusions.append((collider as CollisionObject3D).get_rid())
		if not transparent:
			break
		origin = Vector3(hit.position) + direction * 0.02
	return {
		"protocol": "spring_heaven.perception.v1",
		"role_id": observer_role_id,
		"observed_at_unix": int(Time.get_unix_time_from_system()),
		"observations": observations,
	}

func _find_perceivable(node: Node) -> Node:
	var current := node
	for _depth in 6:
		if not is_instance_valid(current):
			return null
		if current.has_method("get_perception_snapshot"):
			return current
		for child in current.get_children():
			if child.has_method("get_perception_snapshot"):
				return child
		current = current.get_parent()
	return null

func _empty_result() -> Dictionary:
	return {
		"protocol": "spring_heaven.perception.v1",
		"role_id": observer_role_id,
		"observed_at_unix": int(Time.get_unix_time_from_system()),
		"observations": [],
	}
