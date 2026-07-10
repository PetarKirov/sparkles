/**
`sparkles:http` — HTTP/1.1 building blocks over `sparkles:event-horizon`.
Import `sparkles.http` for the whole surface.
*/
module sparkles.http;

public import sparkles.http.message;

version (linux)
{
    public import sparkles.http.server;
}
