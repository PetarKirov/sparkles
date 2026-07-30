module sample;
// @errors: deprecated
// ---cut---
/// The old spelling.
deprecated("use `renderTo` instead")
void render() {}

/// The replacement.
void renderTo(ref int sink) { sink = 1; }

void main()
{
    render();
//  ^?
}
