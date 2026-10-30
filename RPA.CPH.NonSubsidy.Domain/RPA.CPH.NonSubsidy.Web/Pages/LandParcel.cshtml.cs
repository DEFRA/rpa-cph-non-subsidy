using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Pages;

[Authorize(Policy = ApplicationServices.BasicAccessPolicy)]
public sealed class LandParcelModel : PageModel
{
    public PartialViewResult OnGet(LandParcel landParcel) => Partial("_LandParcel", landParcel);
}
