using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace RPA.CPH.NonSubsidy.Web.Pages.Account;

[AllowAnonymous]
public sealed class SignedOutModel : PageModel
{
    public IActionResult OnGet() => Content("You have signed out.");
}
