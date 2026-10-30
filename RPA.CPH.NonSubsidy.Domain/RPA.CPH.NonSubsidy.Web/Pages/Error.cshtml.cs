using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace RPA.CPH.NonSubsidy.Web.Pages;

[AllowAnonymous]
[IgnoreAntiforgeryToken]
public sealed class ErrorModel : PageModel
{
    public Exception Exception { get; private set; }

    public void OnGet() => Exception = HttpContext.Features.Get<IExceptionHandlerFeature>()?.Error;

    // Exception-handler re-execution retains the failed request's HTTP method.
    public void OnPost() => OnGet();
}
