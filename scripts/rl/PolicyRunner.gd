class_name PolicyRunner
extends RefCounted

## Инференс обученной политики прямо в GDScript.
##
## Зачем не ONNX: обёртка godot_rl_agents для ONNX написана на C# и работает
## только в .NET-сборке Godot. А сеть здесь крошечная (50 -> 256 -> 256 -> 5),
## её forward - три матричных умножения, около 80 тысяч операций. При семи
## решениях в секунду это доли процента кадрового бюджета, зато игра
## перестаёт зависеть от запущенного рядом Python.
##
## Файл готовит tools/export_policy.py. Формат:
##   "GLADPOL1", obs_dim, act_dim, n_layers,
##   на слой: in_dim, out_dim, activation, веса (по строкам), смещения,
##   затем контрольные пары obs->action для самопроверки.

const MAGIC := "GLADPOL1"
const ACT_TANH := 1

var obs_dim: int = 0
var act_dim: int = 0
var loaded: bool = false
var load_error: String = ""

# Слои: {w, b, in, out, act}. Буферы под результат выделяются один раз,
# иначе на каждом решении рождался бы мусор для сборщика.
var _layers: Array = []
var _buffers: Array[PackedFloat32Array] = []
var _input: PackedFloat32Array

var _check_obs: PackedFloat32Array
var _check_act: PackedFloat32Array
var _check_count: int = 0


## Сколько наблюдений ждёт политика. Читает только заголовок, поэтому
## годится для проверки совместимости в меню - грузить 300 КБ весов ради
## одного числа не нужно.
static func peek_obs_dim(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var head := f.get_buffer(12)
	f.close()
	if head.size() < 12 or head.slice(0, 8).get_string_from_ascii() != MAGIC:
		return -1
	return head.decode_s32(8)


func load_from(path: String) -> bool:
	loaded = false
	load_error = ""

	if not FileAccess.file_exists(path):
		load_error = "файл политики не найден: " + path
		return false

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 20:
		load_error = "файл политики повреждён"
		return false

	if bytes.slice(0, 8).get_string_from_ascii() != MAGIC:
		load_error = "не тот формат политики"
		return false

	var off := 8
	obs_dim = bytes.decode_s32(off); off += 4
	act_dim = bytes.decode_s32(off); off += 4
	var n_layers := bytes.decode_s32(off); off += 4

	_layers.clear()
	_buffers.clear()

	for i in n_layers:
		var in_dim := bytes.decode_s32(off); off += 4
		var out_dim := bytes.decode_s32(off); off += 4
		var act := bytes.decode_s32(off); off += 4

		var w_bytes := in_dim * out_dim * 4
		var w := bytes.slice(off, off + w_bytes).to_float32_array(); off += w_bytes
		var b := bytes.slice(off, off + out_dim * 4).to_float32_array(); off += out_dim * 4

		_layers.append({"w": w, "b": b, "in": in_dim, "out": out_dim, "act": act})
		var buf := PackedFloat32Array()
		buf.resize(out_dim)
		_buffers.append(buf)

	_check_count = bytes.decode_s32(off); off += 4
	if _check_count > 0:
		var o_bytes := _check_count * obs_dim * 4
		_check_obs = bytes.slice(off, off + o_bytes).to_float32_array(); off += o_bytes
		var a_bytes := _check_count * act_dim * 4
		_check_act = bytes.slice(off, off + a_bytes).to_float32_array()

	_input.resize(obs_dim)
	loaded = true
	return true


## Действие политики при deterministic-инференсе: выход сети, обрезанный
## до допустимого диапазона (ровно то же делает SB3 для Box-пространства).
func predict(obs: Array[float]) -> PackedFloat32Array:
	if not loaded or obs.size() != obs_dim:
		return PackedFloat32Array()

	for i in obs_dim:
		_input[i] = obs[i]

	var cur := _input
	for li in _layers.size():
		cur = _run_layer(cur, _layers[li], _buffers[li])

	for i in cur.size():
		cur[i] = clampf(cur[i], -1.0, 1.0)
	return cur


func _run_layer(inp: PackedFloat32Array, layer: Dictionary,
		out_buf: PackedFloat32Array) -> PackedFloat32Array:
	var w: PackedFloat32Array = layer["w"]
	var b: PackedFloat32Array = layer["b"]
	var in_dim: int = layer["in"]
	var out_dim: int = layer["out"]
	var use_tanh: bool = layer["act"] == ACT_TANH

	for o in out_dim:
		var acc := b[o]
		var base := o * in_dim
		for i in in_dim:
			acc += w[base + i] * inp[i]
		out_buf[o] = tanh(acc) if use_tanh else acc

	return out_buf


## Сверка с PyTorch по контрольным парам из файла.
##
## Без неё ошибка в порядке весов или в активации проявилась бы только как
## «агент играет странно» - самый неприятный вид бага, потому что его легко
## списать на недообученность.
func verify(tolerance: float = 1.0e-3) -> Dictionary:
	if not loaded or _check_count <= 0:
		return {"ok": false, "reason": "нет контрольных пар"}

	var worst := 0.0
	for s in _check_count:
		var o: Array[float] = []
		o.resize(obs_dim)
		for i in obs_dim:
			o[i] = _check_obs[s * obs_dim + i]

		var got := predict(o)
		for i in act_dim:
			worst = maxf(worst, absf(got[i] - _check_act[s * act_dim + i]))

	return {
		"ok": worst <= tolerance,
		"max_diff": worst,
		"samples": _check_count,
	}
