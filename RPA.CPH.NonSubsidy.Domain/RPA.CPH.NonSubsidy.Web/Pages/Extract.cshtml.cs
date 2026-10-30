using System.Text;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Pages;

[Authorize(Policy = ApplicationServices.BasicAccessPolicy)]
public sealed class ExtractModel(IUnitOfWork uow) : PageModel
{
    public IActionResult OnGet()
    {
        var landParcels = uow.LandParcelRepository.FindBy(x => x.Active)
            .OrderBy(x => x.Land.Customer.SBI).ThenBy(x => x.GridReference).ToList();
        var sb = new StringBuilder();
        sb.AppendLine("SBI,BusinessName,BusinessAddress,CPH,PlaceOfBusinessReferenceNumber,AdditionalGridReferences,CRMCaseReferenceNumber,UpdatedBy,Updated");
        foreach (var landParcel in landParcels)
            sb.AppendLine(landParcel.ToCSV());

        var date = DateTime.Now;
        return File(new UTF8Encoding().GetBytes(sb.ToString()), "text/csv",
            $"Non_Subsidy_CPHs_{date.Day}{date.Month}{date.Year}{date.Hour}{date.Minute}.csv");
    }
}
