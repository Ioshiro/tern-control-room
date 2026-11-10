--!strict
-- Pure single-line editing with UTF-16 offsets; malformed bytes count individually.
local field = {}
export type Field = { text: string, caret: number }

--- The byte and UTF-16 unit widths at `i`; an invalid sequence is one byte and one unit.
local function char(text: string, i: number): (number, number)
	local a = string.byte(text, i)
	local b, c, d = string.byte(text, i + 1), string.byte(text, i + 2), string.byte(text, i + 3)
	if a >= 0xC2 and a <= 0xDF and b and b >= 0x80 and b <= 0xBF then
		return 2, 1
	elseif a >= 0xE0 and a <= 0xEF and b and c and b >= 0x80 and b <= 0xBF and c >= 0x80 and c <= 0xBF and (a ~= 0xE0 or b >= 0xA0) and (a ~= 0xED or b < 0xA0) then
		return 3, 1
	elseif a >= 0xF0 and a <= 0xF4 and b and c and d and b >= 0x80 and b <= 0xBF and c >= 0x80 and c <= 0xBF and d >= 0x80 and d <= 0xBF and (a ~= 0xF0 or b >= 0x90) and (a ~= 0xF4 or b < 0x90) then
		return 4, 2
	end
	return 1, 1
end

--- The byte index and unit offset at or before the requested unit offset.
local function position(text: string, target: number): (number, number)
	local i, units = 1, 0
	while i <= #text do
		local bytes, width = char(text, i)
		if units + width > target then
			break
		end
		i += bytes
		units += width
	end
	return i, units
end

--- The length of the text in UTF-16 units.
function field.units(text: string): number
	local _, count = position(text, math.huge)
	return count
end

--- A field with the caret at the end of the text.
function field.of(text: string): Field
	return { text = text, caret = field.units(text) }
end

--- A field with text inserted at the caret.
function field.insert(f: Field, text: string): Field
	local i, caret = position(f.text, f.caret)
	return { text = string.sub(f.text, 1, i - 1) .. text .. string.sub(f.text, i), caret = caret + field.units(text) }
end

--- A field with the caret one character to the left.
function field.left(f: Field): Field
	local _, caret = position(f.text, math.max(0, f.caret - 1))
	return { text = f.text, caret = caret }
end

--- A field with the caret one character to the right.
function field.right(f: Field): Field
	local i, caret = position(f.text, f.caret)
	if i <= #f.text then
		local _, width = char(f.text, i)
		caret += width
	end
	return { text = f.text, caret = caret }
end

--- A field with the caret at the beginning.
function field.home(f: Field): Field
	return { text = f.text, caret = 0 }
end

--- A field with the caret at the end.
function field.finish(f: Field): Field
	return field.of(f.text)
end

--- A field without the character before the caret.
function field.backspace(f: Field): Field
	local previous = field.left(f)
	local a = position(f.text, previous.caret)
	local b = position(f.text, f.caret)
	return { text = string.sub(f.text, 1, a - 1) .. string.sub(f.text, b), caret = previous.caret }
end

--- A field without the character after the caret.
function field.delete(f: Field): Field
	local a, caret = position(f.text, f.caret)
	local b = position(f.text, field.right(f).caret)
	return { text = string.sub(f.text, 1, a - 1) .. string.sub(f.text, b), caret = caret }
end

--- The edited field, or nil when the edit was based on stale text.
function field.edit(f: Field, from: number, to: number, text: string, cursor: number, len: number): Field?
	if field.units(f.text) ~= len then
		return nil
	end
	local a = position(f.text, from)
	local b = position(f.text, to)
	local result = string.sub(f.text, 1, a - 1) .. text .. string.sub(f.text, b)
	local _, caret = position(result, cursor)
	return { text = result, caret = caret }
end

return field
