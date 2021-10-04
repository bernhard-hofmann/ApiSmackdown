var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => ".NET    greets the world");

app.Run();
