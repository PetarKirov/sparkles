module sample;
// @errors: cannot implicitly convert
// ---cut---
void broken()
{
    int x = "not an int";
}
